// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Small iterative radix-2 FFT engine.
//
// Compile-time configuration is intentionally narrow: this implementation is
// optimized for area in Croc's 16-point accelerator use case. FFT_N may be 2,
// 4, 8, or 16; larger sizes need a wider twiddle table.

module fft_iterative #(
  parameter int unsigned FFT_N            = 16,
  parameter int unsigned DATA_WIDTH       = 16,
  parameter int unsigned TWIDDLE_WIDTH    = 16,
  parameter bit          INVERSE          = 1'b0,
  parameter bit          SCALE_EACH_STAGE = 1'b1,
  parameter bit          BIT_REVERSE_LOAD = 1'b1
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,

  input  logic                        start_i,

  input  logic                        sample_valid_i,
  output logic                        sample_ready_o,
  input  logic [2*DATA_WIDTH-1:0]     sample_i,

  output logic                        result_valid_o,
  input  logic                        result_ready_i,
  output logic [2*DATA_WIDTH-1:0]     result_o,

  output logic                        busy_o,
  output logic                        done_o
);

  localparam int unsigned LgN = $clog2(FFT_N);

  typedef logic signed [DATA_WIDTH-1:0]    data_t;
  typedef logic signed [TWIDDLE_WIDTH-1:0] twiddle_t;

  typedef enum logic [1:0] {
    FFT_IDLE,
    FFT_LOAD,
    FFT_COMPUTE,
    FFT_UNLOAD
  } fft_state_e;

  fft_state_e state_q, state_d;

  data_t mem_r_q [FFT_N];
  data_t mem_i_q [FFT_N];

  logic [LgN:0] load_count_q, unload_count_q;
  logic [LgN-1:0] stage_q;
  logic [LgN:0] group_base_q;
  logic [LgN:0] butterfly_j_q;

  logic [LgN-1:0] load_addr;
  logic [LgN:0] half_span;
  logic [LgN:0] span;
  logic [LgN:0] addr_a;
  logic [LgN:0] addr_b;
  logic [3:0]   twiddle_idx;

  data_t a_r, a_i, b_r, b_i;
  twiddle_t tw_r, tw_i;

  logic signed [DATA_WIDTH+TWIDDLE_WIDTH:0] mult_r;
  logic signed [DATA_WIDTH+TWIDDLE_WIDTH:0] mult_i;
  logic signed [DATA_WIDTH:0] sum_r;
  logic signed [DATA_WIDTH:0] sum_i;
  logic signed [DATA_WIDTH:0] diff_r;
  logic signed [DATA_WIDTH:0] diff_i;

  data_t upper_r, upper_i;
  data_t lower_r, lower_i;

  logic last_load;
  logic last_butterfly_in_group;
  logic last_group_in_stage;
  logic last_stage;
  logic last_unload;

  function automatic logic [LgN-1:0] bit_reverse(input logic [LgN-1:0] value);
    for (int i = 0; i < LgN; i++) begin
      bit_reverse[i] = value[LgN-1-i];
    end
  endfunction

  function automatic twiddle_t twiddle_cos_16(input logic [3:0] idx);
    unique case (idx)
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

  function automatic twiddle_t twiddle_sin_16(input logic [3:0] idx);
    unique case (idx)
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

  function automatic data_t narrow_sum(input logic signed [DATA_WIDTH:0] value);
    narrow_sum = data_t'(value[DATA_WIDTH-1:0]);
  endfunction

  assign sample_ready_o = (state_q == FFT_LOAD);
  assign result_valid_o = (state_q == FFT_UNLOAD);
  assign busy_o         = (state_q != FFT_IDLE);
  assign done_o         = result_valid_o & result_ready_i & last_unload;

  assign result_o = {mem_r_q[unload_count_q[LgN-1:0]], mem_i_q[unload_count_q[LgN-1:0]]};

  assign load_addr = BIT_REVERSE_LOAD ? bit_reverse(load_count_q[LgN-1:0]) : load_count_q[LgN-1:0];

  assign half_span = {{LgN{1'b0}}, 1'b1} << stage_q;
  assign span      = half_span << 1;
  assign addr_a    = group_base_q + butterfly_j_q;
  assign addr_b    = addr_a + half_span;

  assign twiddle_idx = butterfly_j_q[3:0] << (4'd3 - {1'b0, stage_q});

  assign a_r = mem_r_q[addr_a[LgN-1:0]];
  assign a_i = mem_i_q[addr_a[LgN-1:0]];
  assign b_r = mem_r_q[addr_b[LgN-1:0]];
  assign b_i = mem_i_q[addr_b[LgN-1:0]];

  assign tw_r = twiddle_cos_16(twiddle_idx);
  assign tw_i = twiddle_sin_16(twiddle_idx);

  generate
    if (INVERSE) begin : gen_inverse_multiply
      assign mult_r = (($signed(tw_r) * $signed(b_r)) - ($signed(tw_i) * $signed(b_i)))
                    >>> (TWIDDLE_WIDTH - 1);
      assign mult_i = (($signed(tw_r) * $signed(b_i)) + ($signed(tw_i) * $signed(b_r)))
                    >>> (TWIDDLE_WIDTH - 1);
    end else begin : gen_forward_multiply
      assign mult_r = (($signed(tw_r) * $signed(b_r)) + ($signed(tw_i) * $signed(b_i)))
                    >>> (TWIDDLE_WIDTH - 1);
      assign mult_i = (($signed(tw_r) * $signed(b_i)) - ($signed(tw_i) * $signed(b_r)))
                    >>> (TWIDDLE_WIDTH - 1);
    end
  endgenerate

  assign sum_r  = $signed({a_r[DATA_WIDTH-1], a_r}) + $signed(mult_r[DATA_WIDTH:0]);
  assign sum_i  = $signed({a_i[DATA_WIDTH-1], a_i}) + $signed(mult_i[DATA_WIDTH:0]);
  assign diff_r = $signed({a_r[DATA_WIDTH-1], a_r}) - $signed(mult_r[DATA_WIDTH:0]);
  assign diff_i = $signed({a_i[DATA_WIDTH-1], a_i}) - $signed(mult_i[DATA_WIDTH:0]);

  generate
    if (SCALE_EACH_STAGE) begin : gen_scaled_outputs
      assign upper_r = narrow_sum(sum_r >>> 1);
      assign upper_i = narrow_sum(sum_i >>> 1);
      assign lower_r = narrow_sum(diff_r >>> 1);
      assign lower_i = narrow_sum(diff_i >>> 1);
    end else begin : gen_unscaled_outputs
      assign upper_r = narrow_sum(sum_r);
      assign upper_i = narrow_sum(sum_i);
      assign lower_r = narrow_sum(diff_r);
      assign lower_i = narrow_sum(diff_i);
    end
  endgenerate

  assign last_load                = sample_valid_i & sample_ready_o & (load_count_q == (FFT_N-1));
  assign last_butterfly_in_group  = butterfly_j_q == (half_span - 1);
  assign last_group_in_stage      = group_base_q == (FFT_N - span);
  assign last_stage               = stage_q == (LgN - 1);
  assign last_unload              = unload_count_q == (FFT_N-1);

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      FFT_IDLE:    if (start_i) state_d = FFT_LOAD;
      FFT_LOAD:    if (last_load) state_d = FFT_COMPUTE;
      FFT_COMPUTE: if (last_butterfly_in_group && last_group_in_stage && last_stage) state_d = FFT_UNLOAD;
      FFT_UNLOAD:  if (result_valid_o && result_ready_i && last_unload) state_d = FFT_IDLE;
      default:     state_d = FFT_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= FFT_IDLE;
      load_count_q     <= '0;
      unload_count_q   <= '0;
      stage_q          <= '0;
      group_base_q     <= '0;
      butterfly_j_q    <= '0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        FFT_IDLE: begin
          load_count_q   <= '0;
          unload_count_q <= '0;
          stage_q        <= '0;
          group_base_q   <= '0;
          butterfly_j_q  <= '0;
        end

        FFT_LOAD: begin
          if (sample_valid_i && sample_ready_o) begin
            mem_r_q[load_addr] <= data_t'(sample_i[2*DATA_WIDTH-1:DATA_WIDTH]);
            mem_i_q[load_addr] <= data_t'(sample_i[DATA_WIDTH-1:0]);
            load_count_q <= load_count_q + 1'b1;
          end
        end

        FFT_COMPUTE: begin
          mem_r_q[addr_a[LgN-1:0]] <= upper_r;
          mem_i_q[addr_a[LgN-1:0]] <= upper_i;
          mem_r_q[addr_b[LgN-1:0]] <= lower_r;
          mem_i_q[addr_b[LgN-1:0]] <= lower_i;

          if (last_butterfly_in_group) begin
            butterfly_j_q <= '0;
            if (last_group_in_stage) begin
              group_base_q <= '0;
              stage_q      <= stage_q + 1'b1;
            end else begin
              group_base_q <= group_base_q + span;
            end
          end else begin
            butterfly_j_q <= butterfly_j_q + 1'b1;
          end
        end

        FFT_UNLOAD: begin
          if (result_valid_o && result_ready_i) begin
            unload_count_q <= unload_count_q + 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (DATA_WIDTH == 16)
      else $fatal(1, "fft_iterative currently expects DATA_WIDTH=16");
    assert (TWIDDLE_WIDTH == 16)
      else $fatal(1, "fft_iterative currently expects TWIDDLE_WIDTH=16");
    assert ((FFT_N == 2) || (FFT_N == 4) || (FFT_N == 8) || (FFT_N == 16))
      else $fatal(1, "fft_iterative supports FFT_N in {2,4,8,16}");
  end
`endif

endmodule
