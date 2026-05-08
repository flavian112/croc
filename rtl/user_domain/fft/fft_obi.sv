// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// Memory-mapped FFT accelerator for the Croc user domain.
//
// Register map, byte offsets relative to the accelerator base address:
//   0x00 CTRL      bit 0: START, write-only, self-clearing
//   0x04 STATUS    bit 0: BUSY, bit 1: DONE, write 1 to DONE to clear
//   0x08 SRC_ADDR  source address of FftLength packed complex input samples
//   0x0C DST_ADDR  destination address for FftLength packed complex output samples
//   0x10 IRQ_CTRL  bit 0: enable completion interrupt while DONE is set
//   0x14 CONFIG    read-only build configuration
//   0x18 CYCLES    read-only cycle count of the previous run
//
// Sample format is one 32-bit word per complex sample:
//   sample[31:16] = signed real component
//   sample[15:0]  = signed imaginary component

module fft_obi
  import croc_pkg::*;
#(
  parameter int unsigned FftLength   = 16,
  parameter int unsigned DataWidth   = 16,
  parameter int unsigned ScalingMode = 1,
  parameter bit          UseRounding = 1'b0,
  parameter bit          UseSaturation = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,

  input  sbr_obi_req_t obi_sbr_req_i,
  output sbr_obi_rsp_t obi_sbr_rsp_o,

  output mgr_obi_req_t obi_mgr_req_o,
  input  mgr_obi_rsp_t obi_mgr_rsp_i,

  output logic irq_o
);

  localparam int unsigned SampleWidth = 2 * DataWidth;
  localparam int unsigned CountWidth  = $clog2(FftLength + 1);
  localparam int unsigned OffsetPad   = 32 - CountWidth - 2;
  localparam int unsigned FftLog2     = $clog2(FftLength);
  localparam logic [7:0]  FftLengthCfg = 8'(FftLength);
  localparam logic [3:0]  FftLog2Cfg   = 4'(FftLog2);
  localparam logic [7:0]  DataWidthCfg = 8'(DataWidth);
  localparam logic [1:0]  ScalingCfg   = 2'(ScalingMode);

  typedef enum logic [2:0] {
    StateIdle,
    StateFetch,
    StateCompute,
    StateStore
  } state_e;

  typedef enum logic [5:0] {
    RegCtrl    = 6'h00,
    RegStatus  = 6'h01,
    RegSrcAddr = 6'h02,
    RegDstAddr = 6'h03,
    RegIrqCtrl = 6'h04,
    RegConfig  = 6'h05,
    RegCycles  = 6'h06
  } reg_addr_e;

  state_e state_q, state_d;

  logic [CountWidth-1:0] fetch_req_count_q;
  logic [CountWidth-1:0] fetch_rsp_count_q;
  logic [CountWidth-1:0] store_req_count_q;
  logic [CountWidth-1:0] store_rsp_count_q;
  logic [31:0]           fetch_byte_offset;
  logic [31:0]           store_byte_offset;

  logic [31:0] src_addr_q;
  logic [31:0] dst_addr_q;
  logic [31:0] cycle_count_q;
  logic [31:0] last_cycles_q;
  logic        irq_en_q;
  logic        busy_q;
  logic        done_q;
  logic        transfer_complete;
  logic        status_done_clear;

  logic ctrl_start_write;
  assign ctrl_start_write = obi_sbr_req_i.req
                          & obi_sbr_req_i.a.we
                          & (reg_addr_e'(obi_sbr_req_i.a.addr[7:2]) == RegCtrl)
                          & obi_sbr_req_i.a.wdata[0];

  logic start_pulse;
  assign start_pulse = ctrl_start_write & (state_q == StateIdle);
  assign fetch_byte_offset = {{OffsetPad{1'b0}}, fetch_req_count_q, 2'b00};
  assign store_byte_offset = {{OffsetPad{1'b0}}, store_req_count_q, 2'b00};
  assign transfer_complete = (state_q == StateStore)
                           && (store_rsp_count_q == (FftLength - 1))
                           && obi_mgr_rsp_i.rvalid;
  assign status_done_clear = obi_sbr_req_i.req
                           & obi_sbr_req_i.a.we
                           & (reg_addr_e'(obi_sbr_req_i.a.addr[7:2]) == RegStatus)
                           & obi_sbr_req_i.a.wdata[1];

  logic [31:0] config_value;
  assign config_value = {
    4'h0,
    1'b1,                  // input is bit-reversed before the iterative stages
    ScalingCfg,            // compile-time scaling mode
    1'b0,                  // forward FFT
    DataWidthCfg,
    4'h0,
    FftLog2Cfg,
    FftLengthCfg
  };

  // ---------------------------------------------------------------------------
  // OBI subordinate register interface
  // ---------------------------------------------------------------------------

  logic                                  sbr_req_q;
  logic [31:0]                           sbr_addr_q;
  logic                                  sbr_we_q;
  logic [$bits(obi_sbr_req_i.a.aid)-1:0] sbr_aid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sbr_req_q  <= 1'b0;
      sbr_addr_q <= '0;
      sbr_we_q   <= 1'b0;
      sbr_aid_q  <= '0;
    end else begin
      sbr_req_q  <= obi_sbr_req_i.req;
      sbr_addr_q <= obi_sbr_req_i.a.addr;
      sbr_we_q   <= obi_sbr_req_i.a.we;
      sbr_aid_q  <= obi_sbr_req_i.a.aid;
    end
  end

  assign obi_sbr_rsp_o.gnt          = 1'b1;
  assign obi_sbr_rsp_o.rvalid       = sbr_req_q;
  assign obi_sbr_rsp_o.r.rid        = sbr_aid_q;
  assign obi_sbr_rsp_o.r.err        = 1'b0;
  assign obi_sbr_rsp_o.r.r_optional = '0;

  always_comb begin
    obi_sbr_rsp_o.r.rdata = 32'h0;

    if (sbr_req_q && !sbr_we_q) begin
      unique case (reg_addr_e'(sbr_addr_q[7:2]))
        RegCtrl:    obi_sbr_rsp_o.r.rdata = 32'h0;
        RegStatus:  obi_sbr_rsp_o.r.rdata = {30'h0, done_q, busy_q};
        RegSrcAddr: obi_sbr_rsp_o.r.rdata = src_addr_q;
        RegDstAddr: obi_sbr_rsp_o.r.rdata = dst_addr_q;
        RegIrqCtrl: obi_sbr_rsp_o.r.rdata = {31'h0, irq_en_q};
        RegConfig:  obi_sbr_rsp_o.r.rdata = config_value;
        RegCycles:  obi_sbr_rsp_o.r.rdata = last_cycles_q;
        default:    obi_sbr_rsp_o.r.rdata = 32'h0;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_addr_q <= '0;
      dst_addr_q <= '0;
      irq_en_q   <= 1'b0;
    end else if (obi_sbr_req_i.req && obi_sbr_req_i.a.we) begin
      unique case (reg_addr_e'(obi_sbr_req_i.a.addr[7:2]))
        RegSrcAddr: src_addr_q <= obi_sbr_req_i.a.wdata;
        RegDstAddr: dst_addr_q <= obi_sbr_req_i.a.wdata;
        RegIrqCtrl: irq_en_q   <= obi_sbr_req_i.a.wdata[0];
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // FFT core interface
  // ---------------------------------------------------------------------------

  logic                    fft_sample_valid;
  logic                    fft_sample_ready;
  logic [SampleWidth-1:0]  fft_sample;
  logic                    fft_result_valid;
  logic                    fft_result_ready;
  logic [SampleWidth-1:0]  fft_result;
  logic                    fft_busy;
  logic                    fft_done;

  assign fft_sample_valid = (state_q == StateFetch) && obi_mgr_rsp_i.rvalid;
  assign fft_sample       = obi_mgr_rsp_i.r.rdata[SampleWidth-1:0];
  assign fft_result_ready = (state_q == StateStore) && obi_mgr_req_o.req && obi_mgr_rsp_i.gnt;

  logic unused_inputs;
  assign unused_inputs = testmode_i ^ fft_busy ^ fft_done;

  fft_core #(
    .FftLength       ( FftLength ),
    .DataWidth       ( DataWidth ),
    .TwiddleWidth    ( 16        ),
    .Inverse         ( 1'b0      ),
    .ScalingMode     ( ScalingMode ),
    .BitReverseInput ( 1'b1      ),
    .UseRounding     ( UseRounding ),
    .UseSaturation   ( UseSaturation )
  ) i_fft_core (
    .clk_i,
    .rst_ni,
    .start_i        ( start_pulse      ),
    .sample_valid_i ( fft_sample_valid ),
    .sample_ready_o ( fft_sample_ready ),
    .sample_i       ( fft_sample       ),
    .result_valid_o ( fft_result_valid ),
    .result_ready_i ( fft_result_ready ),
    .result_o       ( fft_result       ),
    .busy_o         ( fft_busy         ),
    .done_o         ( fft_done         )
  );

  // ---------------------------------------------------------------------------
  // Transfer FSM
  // ---------------------------------------------------------------------------

  always_comb begin
    state_d = state_q;

    unique case (state_q)
      StateIdle:    if (start_pulse) state_d = StateFetch;
      StateFetch:   if (fetch_rsp_count_q == (FftLength - 1) && obi_mgr_rsp_i.rvalid) state_d = StateCompute;
      StateCompute: if (fft_result_valid) state_d = StateStore;
      StateStore:   if (store_rsp_count_q == (FftLength - 1) && obi_mgr_rsp_i.rvalid) state_d = StateIdle;
      default:      state_d = StateIdle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= StateIdle;
      fetch_req_count_q <= '0;
      fetch_rsp_count_q <= '0;
      store_req_count_q <= '0;
      store_rsp_count_q <= '0;
      busy_q            <= 1'b0;
      done_q            <= 1'b0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        StateIdle: begin
          if (start_pulse) begin
            fetch_req_count_q <= '0;
            fetch_rsp_count_q <= '0;
            store_req_count_q <= '0;
            store_rsp_count_q <= '0;
            busy_q            <= 1'b1;
            done_q            <= 1'b0;
          end else if (status_done_clear) begin
            done_q <= 1'b0;
          end
        end

        StateFetch: begin
          if (obi_mgr_req_o.req && obi_mgr_rsp_i.gnt && (fetch_req_count_q < FftLength)) begin
            fetch_req_count_q <= fetch_req_count_q + 1'b1;
          end

          if (obi_mgr_rsp_i.rvalid && (fetch_rsp_count_q < FftLength)) begin
            fetch_rsp_count_q <= fetch_rsp_count_q + 1'b1;
          end
        end

        StateStore: begin
          if (obi_mgr_req_o.req && obi_mgr_rsp_i.gnt && (store_req_count_q < FftLength)) begin
            store_req_count_q <= store_req_count_q + 1'b1;
          end

          if (obi_mgr_rsp_i.rvalid && (store_rsp_count_q < FftLength)) begin
            store_rsp_count_q <= store_rsp_count_q + 1'b1;
          end

          if (transfer_complete) begin
            busy_q <= 1'b0;
            done_q <= 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

  // Counts the full accelerator transaction, including source reads, iterative
  // compute, and destination writes. The value is informational only and does
  // not feed back into the transfer FSM.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycle_count_q <= '0;
      last_cycles_q <= '0;
    end else if (start_pulse) begin
      cycle_count_q <= '0;
    end else if (transfer_complete) begin
      cycle_count_q <= cycle_count_q + 1'b1;
      last_cycles_q <= cycle_count_q + 1'b1;
    end else if (busy_q) begin
      cycle_count_q <= cycle_count_q + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // OBI manager DMA interface
  // ---------------------------------------------------------------------------

  always_comb begin
    obi_mgr_req_o      = '0;
    obi_mgr_req_o.a.be = 4'hF;

    unique case (state_q)
      StateFetch: begin
        if ((fetch_req_count_q < FftLength) && fft_sample_ready) begin
          obi_mgr_req_o.req    = 1'b1;
          obi_mgr_req_o.a.we   = 1'b0;
          obi_mgr_req_o.a.addr = src_addr_q + fetch_byte_offset;
        end
      end

      StateStore: begin
        if ((store_req_count_q < FftLength) && fft_result_valid) begin
          obi_mgr_req_o.req     = 1'b1;
          obi_mgr_req_o.a.we    = 1'b1;
          obi_mgr_req_o.a.addr  = dst_addr_q + store_byte_offset;
          obi_mgr_req_o.a.wdata = fft_result;
        end
      end

      default: ;
    endcase
  end

  assign irq_o = irq_en_q & done_q;

endmodule
