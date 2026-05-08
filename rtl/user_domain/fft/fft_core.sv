// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Small iterative radix-2 FFT core.
//
// This core is intentionally area-oriented: it stores the full vector locally
// and reuses one butterfly datapath. The supported configuration space is kept
// narrow because Croc currently needs only a compact fixed-point accelerator.

module fft_core #(
  parameter int unsigned FftLength       = 16,
  parameter int unsigned DataWidth       = 16,
  parameter int unsigned TwiddleWidth    = 16,
  parameter bit          Inverse         = 1'b0,
  parameter int unsigned ScalingMode     = 1,
  parameter bit          BitReverseInput = 1'b1,
  parameter bit          UseRounding     = 1'b0,
  parameter bit          UseSaturation   = 1'b0
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,

  input  logic                       start_i,

  input  logic                       sample_valid_i,
  output logic                       sample_ready_o,
  input  logic [2*DataWidth-1:0]     sample_i,

  output logic                       result_valid_o,
  input  logic                       result_ready_i,
  output logic [2*DataWidth-1:0]     result_o,

  output logic                       busy_o,
  output logic                       done_o
);

  localparam int unsigned IndexWidth = $clog2(FftLength);
  localparam int unsigned ScaleNone      = 0;
  localparam int unsigned ScaleEachStage = 1;

  typedef logic signed [DataWidth-1:0]    data_t;
  typedef logic signed [TwiddleWidth-1:0] twiddle_t;

  typedef enum logic [1:0] {
    StateIdle,
    StateLoad,
    StateCompute,
    StateUnload
  } state_e;

  state_e state_q, state_d;

  data_t real_mem_q [FftLength];
  data_t imag_mem_q [FftLength];

  logic [IndexWidth:0]   load_count_q;
  logic [IndexWidth:0]   unload_count_q;
  logic [IndexWidth-1:0] stage_q;
  logic [IndexWidth:0]   group_base_q;
  logic [IndexWidth:0]   butterfly_index_q;

  logic [IndexWidth-1:0] load_addr;
  logic [IndexWidth:0]   half_span;
  logic [IndexWidth:0]   span;
  logic [IndexWidth:0]   lower_addr;
  logic [IndexWidth:0]   upper_addr;
  logic [3:0]            twiddle_index;

  data_t lower_real;
  data_t lower_imag;
  data_t upper_real;
  data_t upper_imag;
  twiddle_t twiddle_real;
  twiddle_t twiddle_imag;

  logic signed [DataWidth+TwiddleWidth:0] product_real;
  logic signed [DataWidth+TwiddleWidth:0] product_imag;
  logic signed [DataWidth:0]              sum_real;
  logic signed [DataWidth:0]              sum_imag;
  logic signed [DataWidth:0]              diff_real;
  logic signed [DataWidth:0]              diff_imag;

  data_t next_lower_real;
  data_t next_lower_imag;
  data_t next_upper_real;
  data_t next_upper_imag;

  logic accept_sample;
  logic accept_result;
  logic last_load;
  logic last_butterfly_in_group;
  logic last_group_in_stage;
  logic last_stage;
  logic last_unload;

  function automatic logic [IndexWidth-1:0] bit_reverse(input logic [IndexWidth-1:0] value);
    for (int index = 0; index < IndexWidth; index++) begin
      bit_reverse[index] = value[IndexWidth-1-index];
    end
  endfunction

  function automatic twiddle_t twiddle_cos_16(input logic [3:0] index);
    unique case (index)
      4'd0: twiddle_cos_16 = 16'sd32767;
      4'd1: twiddle_cos_16 = 16'sd30274;
      4'd2: twiddle_cos_16 = 16'sd23170;
      4'd3: twiddle_cos_16 = 16'sd12540;
      4'd4: twiddle_cos_16 = 16'sd0;
      4'd5: twiddle_cos_16 = -16'sd12540;
      4'd6: twiddle_cos_16 = -16'sd23170;
      4'd7: twiddle_cos_16 = -16'sd30274;
      default: twiddle_cos_16 = 16'sd0;
    endcase
  endfunction

  function automatic twiddle_t twiddle_sin_16(input logic [3:0] index);
    unique case (index)
      4'd0: twiddle_sin_16 = 16'sd0;
      4'd1: twiddle_sin_16 = 16'sd12540;
      4'd2: twiddle_sin_16 = 16'sd23170;
      4'd3: twiddle_sin_16 = 16'sd30274;
      4'd4: twiddle_sin_16 = 16'sd32767;
      4'd5: twiddle_sin_16 = 16'sd30274;
      4'd6: twiddle_sin_16 = 16'sd23170;
      4'd7: twiddle_sin_16 = 16'sd12540;
      default: twiddle_sin_16 = 16'sd0;
    endcase
  endfunction

  function automatic data_t narrow(input logic signed [DataWidth:0] value);
    narrow = data_t'(value[DataWidth-1:0]);
  endfunction

  function automatic data_t saturate(input logic signed [DataWidth:0] value);
    // Detect overflow by checking if sign extension mismatches the result sign bit.
    // If value[DataWidth:DataWidth-1] == 2'b01, positive overflow -> saturate to max (0x7FFF)
    // If value[DataWidth:DataWidth-1] == 2'b10, negative overflow -> saturate to min (0x8000)
    if (value[DataWidth] != value[DataWidth-1]) begin
      if (value[DataWidth-1]) begin
        saturate = data_t'({1'b1, {(DataWidth-1){1'b0}}}); // Min: 0x8000
      end else begin
        saturate = data_t'({1'b0, {(DataWidth-1){1'b1}}}); // Max: 0x7FFF
      end
    end else begin
      saturate = data_t'(value[DataWidth-1:0]);
    end
  endfunction

  assign sample_ready_o = state_q == StateLoad;
  assign result_valid_o = state_q == StateUnload;
  assign busy_o         = state_q != StateIdle;
  assign done_o         = accept_result & last_unload;

  assign accept_sample = sample_valid_i & sample_ready_o;
  assign accept_result = result_valid_o & result_ready_i;

  assign result_o = {
    real_mem_q[unload_count_q[IndexWidth-1:0]],
    imag_mem_q[unload_count_q[IndexWidth-1:0]]
  };

  assign load_addr  = BitReverseInput ? bit_reverse(load_count_q[IndexWidth-1:0])
                                      : load_count_q[IndexWidth-1:0];
  assign half_span  = {{IndexWidth{1'b0}}, 1'b1} << stage_q;
  assign span       = half_span << 1;
  assign lower_addr = group_base_q + butterfly_index_q;
  assign upper_addr = lower_addr + half_span;

  // The table stores twiddles for a 16-point FFT. Smaller FFTs use a stride.
  assign twiddle_index = butterfly_index_q[3:0] << (4'd3 - {1'b0, stage_q});

  assign lower_real  = real_mem_q[lower_addr[IndexWidth-1:0]];
  assign lower_imag  = imag_mem_q[lower_addr[IndexWidth-1:0]];
  assign upper_real  = real_mem_q[upper_addr[IndexWidth-1:0]];
  assign upper_imag  = imag_mem_q[upper_addr[IndexWidth-1:0]];
  assign twiddle_real = twiddle_cos_16(twiddle_index);
  assign twiddle_imag = twiddle_sin_16(twiddle_index);

  generate
    if (Inverse) begin : gen_inverse_twiddle_multiply
      assign product_real = (($signed(twiddle_real) * $signed(upper_real))
                           - ($signed(twiddle_imag) * $signed(upper_imag))) >>> (TwiddleWidth - 1);
      assign product_imag = (($signed(twiddle_real) * $signed(upper_imag))
                           + ($signed(twiddle_imag) * $signed(upper_real))) >>> (TwiddleWidth - 1);
    end else begin : gen_forward_twiddle_multiply
      assign product_real = (($signed(twiddle_real) * $signed(upper_real))
                           + ($signed(twiddle_imag) * $signed(upper_imag))) >>> (TwiddleWidth - 1);
      assign product_imag = (($signed(twiddle_real) * $signed(upper_imag))
                           - ($signed(twiddle_imag) * $signed(upper_real))) >>> (TwiddleWidth - 1);
    end
  endgenerate

  assign sum_real  = $signed({lower_real[DataWidth-1], lower_real}) + $signed(product_real[DataWidth:0]);
  assign sum_imag  = $signed({lower_imag[DataWidth-1], lower_imag}) + $signed(product_imag[DataWidth:0]);
  assign diff_real = $signed({lower_real[DataWidth-1], lower_real}) - $signed(product_real[DataWidth:0]);
  assign diff_imag = $signed({lower_imag[DataWidth-1], lower_imag}) - $signed(product_imag[DataWidth:0]);

  generate
    if (ScalingMode == ScaleEachStage) begin : gen_scaled_butterfly
      if (UseRounding) begin : gen_rounded_butterfly
        // Round-to-nearest-even: add 1 before right-shift by 1
        if (UseSaturation) begin : gen_rounded_saturated_butterfly
          assign next_lower_real = saturate((sum_real + 1) >>> 1);
          assign next_lower_imag = saturate((sum_imag + 1) >>> 1);
          assign next_upper_real = saturate((diff_real + 1) >>> 1);
          assign next_upper_imag = saturate((diff_imag + 1) >>> 1);
        end else begin : gen_rounded_truncated_butterfly
          assign next_lower_real = narrow((sum_real + 1) >>> 1);
          assign next_lower_imag = narrow((sum_imag + 1) >>> 1);
          assign next_upper_real = narrow((diff_real + 1) >>> 1);
          assign next_upper_imag = narrow((diff_imag + 1) >>> 1);
        end
      end else begin : gen_truncated_butterfly
        // Truncation: arithmetic right shift discards LSB
        if (UseSaturation) begin : gen_truncated_saturated_butterfly
          assign next_lower_real = saturate(sum_real >>> 1);
          assign next_lower_imag = saturate(sum_imag >>> 1);
          assign next_upper_real = saturate(diff_real >>> 1);
          assign next_upper_imag = saturate(diff_imag >>> 1);
        end else begin : gen_truncated_wrapped_butterfly
          assign next_lower_real = narrow(sum_real >>> 1);
          assign next_lower_imag = narrow(sum_imag >>> 1);
          assign next_upper_real = narrow(diff_real >>> 1);
          assign next_upper_imag = narrow(diff_imag >>> 1);
        end
      end
    end else if (ScalingMode == ScaleNone) begin : gen_unscaled_butterfly
      if (UseSaturation) begin : gen_unscaled_saturated_butterfly
        assign next_lower_real = saturate(sum_real);
        assign next_lower_imag = saturate(sum_imag);
        assign next_upper_real = saturate(diff_real);
        assign next_upper_imag = saturate(diff_imag);
      end else begin : gen_unscaled_wrapped_butterfly
        assign next_lower_real = narrow(sum_real);
        assign next_lower_imag = narrow(sum_imag);
        assign next_upper_real = narrow(diff_real);
        assign next_upper_imag = narrow(diff_imag);
      end
    end else begin : gen_invalid_scaling_mode
      assign next_lower_real = '0;
      assign next_lower_imag = '0;
      assign next_upper_real = '0;
      assign next_upper_imag = '0;
    end
  endgenerate

  assign last_load               = accept_sample && (load_count_q == (FftLength - 1));
  assign last_butterfly_in_group = butterfly_index_q == (half_span - 1);
  assign last_group_in_stage     = group_base_q == (FftLength - span);
  assign last_stage              = stage_q == (IndexWidth - 1);
  assign last_unload             = unload_count_q == (FftLength - 1);

  always_comb begin
    state_d = state_q;

    unique case (state_q)
      StateIdle:    if (start_i) state_d = StateLoad;
      StateLoad:    if (last_load) state_d = StateCompute;
      StateCompute: if (last_butterfly_in_group && last_group_in_stage && last_stage) state_d = StateUnload;
      StateUnload:  if (accept_result && last_unload) state_d = StateIdle;
      default:      state_d = StateIdle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= StateIdle;
      load_count_q      <= '0;
      unload_count_q    <= '0;
      stage_q           <= '0;
      group_base_q      <= '0;
      butterfly_index_q <= '0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        StateIdle: begin
          load_count_q      <= '0;
          unload_count_q    <= '0;
          stage_q           <= '0;
          group_base_q      <= '0;
          butterfly_index_q <= '0;
        end

        StateLoad: begin
          if (accept_sample) begin
            load_count_q <= load_count_q + 1'b1;
          end
        end

        StateCompute: begin
          if (last_butterfly_in_group) begin
            butterfly_index_q <= '0;
            if (last_group_in_stage) begin
              group_base_q <= '0;
              stage_q      <= stage_q + 1'b1;
            end else begin
              group_base_q <= group_base_q + span;
            end
          end else begin
            butterfly_index_q <= butterfly_index_q + 1'b1;
          end
        end

        StateUnload: begin
          if (accept_result) begin
            unload_count_q <= unload_count_q + 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

  // The data memory is intentionally not reset. Every location is overwritten
  // during StateLoad before it is read by StateCompute.
  always_ff @(posedge clk_i) begin
    if (accept_sample) begin
      real_mem_q[load_addr] <= data_t'(sample_i[2*DataWidth-1:DataWidth]);
      imag_mem_q[load_addr] <= data_t'(sample_i[DataWidth-1:0]);
    end else if (state_q == StateCompute) begin
      real_mem_q[lower_addr[IndexWidth-1:0]] <= next_lower_real;
      imag_mem_q[lower_addr[IndexWidth-1:0]] <= next_lower_imag;
      real_mem_q[upper_addr[IndexWidth-1:0]] <= next_upper_real;
      imag_mem_q[upper_addr[IndexWidth-1:0]] <= next_upper_imag;
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (DataWidth == 16)
      else $fatal(1, "fft_core currently expects DataWidth=16");
    assert (TwiddleWidth == 16)
      else $fatal(1, "fft_core currently expects TwiddleWidth=16");
    assert ((FftLength == 2) || (FftLength == 4) || (FftLength == 8) || (FftLength == 16))
      else $fatal(1, "fft_core supports FftLength in {2,4,8,16}");
    assert ((ScalingMode == ScaleNone) || (ScalingMode == ScaleEachStage))
      else $fatal(1, "fft_core supports scaling modes 0=none and 1=each-stage");
  end
`endif

endmodule
