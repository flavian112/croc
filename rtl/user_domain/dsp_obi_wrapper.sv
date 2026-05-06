// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

// 16-point fixed-point FFT accelerator for the Croc SoC user domain.
//
// Uses a small iterative radix-2 FFT core with one reused butterfly datapath.
//   IWIDTH = 16 (16 bits per component in/out)
//
// Register map (byte addresses relative to base, i.e. relative to UserBaseAddr+0x1000 = 0x2000_1000):
//   +0x00  CTRL      [0]=START (self-clearing write-only)
//   +0x04  STATUS    [0]=BUSY, [1]=DONE
//   +0x08  SRC_ADDR  32-bit source address for 16 packed complex samples
//   +0x0C  DST_ADDR  32-bit destination address for 16 packed FFT outputs
//   +0x10  IRQ_CTRL  [0]=irq_enable
//
// Data format: each 32-bit word = {real[15:0], imag[15:0]}
//   Input : 16 words at SRC_ADDR  (64 bytes)
//   Output: 16 words at DST_ADDR  (64 bytes)
//
// OBI subordinate: control registers, always clocked on clk_i (not gated).
// OBI manager    : DMA port -- reads inputs from SRAM (FETCH), writes outputs to SRAM (STORE).
//                  FETCH and STORE never overlap (different FSM states).
//
// The FFT core stays on clk_i and uses valid/ready handshakes to avoid a separate
// high-fanout generated clock tree.

module dsp_obi_wrapper
  import croc_pkg::*;
(
  input  logic clk_i,
  input  logic rst_ni,
  input  logic testmode_i,

  // OBI Subordinate port: control registers (from CPU via user domain demux)
  input  sbr_obi_req_t obi_sbr_req_i,
  output sbr_obi_rsp_t obi_sbr_rsp_o,

  // OBI Manager port: DMA (reads input samples, writes FFT outputs)
  output mgr_obi_req_t obi_mgr_req_o,
  input  mgr_obi_rsp_t obi_mgr_rsp_i,

  // Interrupt: pulses high for one cycle when FFT completes (gated by irq_enable)
  output logic irq_o
);

  // ---------------------------------------------------------------------------
  // FFT parameters
  // ---------------------------------------------------------------------------
  localparam int unsigned IWIDTH = 16;
  localparam int unsigned FFT_N  = 16;

  // ---------------------------------------------------------------------------
  // FSM states
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    DSP_IDLE,       // waiting for START
    DSP_FETCH,      // issue 16 OBI reads, feed samples into FFT
    DSP_COMPUTE,    // wait until the iterative FFT presents the first result
    DSP_STORE       // issue 16 OBI writes with FFT output
  } dsp_state_e;

  dsp_state_e state_q, state_d;

  logic [4:0] fetch_req_q;   // OBI read requests accepted
  logic [4:0] fetch_rsp_q;   // OBI read responses received
  logic [4:0] store_req_q;   // OBI write requests accepted
  logic [4:0] store_rsp_q;   // OBI write responses received

  // ---------------------------------------------------------------------------
  // Control / status registers
  // ---------------------------------------------------------------------------
  logic [31:0] src_addr_q, dst_addr_q;
  logic        irq_en_q;
  logic        busy_q, done_q;

  // start_pulse: one-cycle signal when CPU writes CTRL.START=1 while IDLE
  logic start_pulse;
  assign start_pulse = obi_sbr_req_i.req
                     & obi_sbr_req_i.a.we
                     & (obi_sbr_req_i.a.addr[7:2] == 6'h00)
                     & obi_sbr_req_i.a.wdata[0]
                     & (state_q == DSP_IDLE);

  // ---------------------------------------------------------------------------
  // OBI Subordinate -- register bank (always on clk_i, not gated)
  // Standard 1-cycle-latency OBI subordinate: gnt=1 combinatorially,
  // rvalid one cycle after req.
  // ---------------------------------------------------------------------------
  logic                                  sbr_req_q;
  logic [31:0]                           sbr_addr_q;
  logic                                  sbr_we_q;
  logic [31:0]                           sbr_wdata_q;
  logic [$bits(obi_sbr_req_i.a.aid)-1:0] sbr_aid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sbr_req_q   <= 1'b0;
      sbr_addr_q  <= '0;
      sbr_we_q    <= 1'b0;
      sbr_wdata_q <= '0;
      sbr_aid_q   <= '0;
    end else begin
      sbr_req_q   <= obi_sbr_req_i.req;
      sbr_addr_q  <= obi_sbr_req_i.a.addr;
      sbr_we_q    <= obi_sbr_req_i.a.we;
      sbr_wdata_q <= obi_sbr_req_i.a.wdata;
      sbr_aid_q   <= obi_sbr_req_i.a.aid;
    end
  end

  // Grant always immediately
  assign obi_sbr_rsp_o.gnt          = 1'b1;
  // Response one cycle later
  assign obi_sbr_rsp_o.rvalid       = sbr_req_q;
  assign obi_sbr_rsp_o.r.rid        = sbr_aid_q;
  assign obi_sbr_rsp_o.r.err        = 1'b0;
  assign obi_sbr_rsp_o.r.r_optional = '0;

  // Read data decode (uses registered address / we)
  always_comb begin
    obi_sbr_rsp_o.r.rdata = 32'h0;
    if (sbr_req_q && !sbr_we_q) begin
      unique case (sbr_addr_q[7:2])
        6'h00: obi_sbr_rsp_o.r.rdata = 32'h0;                    // CTRL  (write-only)
        6'h01: obi_sbr_rsp_o.r.rdata = {30'h0, done_q, busy_q};  // STATUS
        6'h02: obi_sbr_rsp_o.r.rdata = src_addr_q;               // SRC_ADDR
        6'h03: obi_sbr_rsp_o.r.rdata = dst_addr_q;               // DST_ADDR
        6'h04: obi_sbr_rsp_o.r.rdata = {31'h0, irq_en_q};        // IRQ_CTRL
        default: obi_sbr_rsp_o.r.rdata = 32'h0;
      endcase
    end
  end

  // Register writes (combinatorial decode on incoming request)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      src_addr_q <= '0;
      dst_addr_q <= '0;
      irq_en_q   <= 1'b0;
    end else if (obi_sbr_req_i.req && obi_sbr_req_i.a.we) begin
      unique case (obi_sbr_req_i.a.addr[7:2])
        6'h02: src_addr_q <= obi_sbr_req_i.a.wdata;
        6'h03: dst_addr_q <= obi_sbr_req_i.a.wdata;
        6'h04: irq_en_q   <= obi_sbr_req_i.a.wdata[0];
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // FSM -- next-state logic (combinatorial)
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      DSP_IDLE:    if (start_pulse)                                      state_d = DSP_FETCH;
      DSP_FETCH:   if (fetch_rsp_q == (FFT_N-1) && obi_mgr_rsp_i.rvalid) state_d = DSP_COMPUTE;
      DSP_COMPUTE: if (fft_result_valid)                                 state_d = DSP_STORE;
      DSP_STORE:   if (store_rsp_q == (FFT_N-1) && obi_mgr_rsp_i.rvalid) state_d = DSP_IDLE;
      default:                                                           state_d = DSP_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // FSM -- registered state and counters
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= DSP_IDLE;
      fetch_req_q <= '0;
      fetch_rsp_q <= '0;
      store_req_q <= '0;
      store_rsp_q <= '0;
      busy_q      <= 1'b0;
      done_q      <= 1'b0;
    end else begin
      state_q <= state_d;

      case (state_q)
        DSP_IDLE: begin
          if (start_pulse) begin
            busy_q      <= 1'b1;
            done_q      <= 1'b0;
            fetch_req_q <= '0;
            fetch_rsp_q <= '0;
            store_req_q <= '0;
            store_rsp_q <= '0;
          end
        end

        DSP_FETCH: begin
          // Count accepted read requests
          if (obi_mgr_req_o.req && obi_mgr_rsp_i.gnt && (fetch_req_q < FFT_N))
            fetch_req_q <= fetch_req_q + 5'd1;
          // Count read responses; each rvalid feeds one sample into the FFT
          if (obi_mgr_rsp_i.rvalid && (fetch_rsp_q < FFT_N))
            fetch_rsp_q <= fetch_rsp_q + 5'd1;
        end

        DSP_COMPUTE: ; // waiting for first FFT output

        DSP_STORE: begin
          // Count accepted write requests
          if (obi_mgr_req_o.req && obi_mgr_rsp_i.gnt && (store_req_q < FFT_N))
            store_req_q <= store_req_q + 5'd1;
          // Count write acks
          if (obi_mgr_rsp_i.rvalid && (store_rsp_q < FFT_N))
            store_rsp_q <= store_rsp_q + 5'd1;
          // Done when last write ack received
          if (store_rsp_q == (FFT_N-1) && obi_mgr_rsp_i.rvalid) begin
            busy_q <= 1'b0;
            done_q <= 1'b1;
          end
        end

        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Iterative FFT core
  // ---------------------------------------------------------------------------
  logic                    fft_sample_valid;
  logic                    fft_sample_ready;
  logic [2*IWIDTH-1:0]     fft_sample;
  logic                    fft_result_valid;
  logic                    fft_result_ready;
  logic [2*IWIDTH-1:0]     fft_result;
  logic                    fft_busy;
  logic                    fft_done;

  assign fft_sample_valid = (state_q == DSP_FETCH) && obi_mgr_rsp_i.rvalid;
  assign fft_sample       = obi_mgr_rsp_i.r.rdata[2*IWIDTH-1:0];
  logic unused_fft_signals;
  assign unused_fft_signals = testmode_i ^ fft_busy ^ fft_done;

  fft_iterative #(
    .FFT_N            ( FFT_N ),
    .DATA_WIDTH       ( IWIDTH ),
    .TWIDDLE_WIDTH    ( 16 ),
    .INVERSE          ( 1'b0 ),
    .SCALE_EACH_STAGE ( 1'b1 ),
    .BIT_REVERSE_LOAD ( 1'b1 )
  ) i_fft_iterative (
    .clk_i,
    .rst_ni,
    .start_i         ( start_pulse        ),
    .sample_valid_i  ( fft_sample_valid   ),
    .sample_ready_o  ( fft_sample_ready   ),
    .sample_i        ( fft_sample         ),
    .result_valid_o  ( fft_result_valid   ),
    .result_ready_i  ( fft_result_ready   ),
    .result_o        ( fft_result         ),
    .busy_o          ( fft_busy           ),
    .done_o          ( fft_done           )
  );

  // ---------------------------------------------------------------------------
  // OBI Manager -- DMA reads (FETCH) and writes (STORE)
  // ---------------------------------------------------------------------------
  assign fft_result_ready = (state_q == DSP_STORE) && obi_mgr_req_o.req && obi_mgr_rsp_i.gnt;

  always_comb begin
    obi_mgr_req_o         = '0;
    obi_mgr_req_o.a.be    = 4'hF;   // full 32-bit word access

    unique case (state_q)
      DSP_FETCH: begin
        if (fetch_req_q < FFT_N && fft_sample_ready) begin
          obi_mgr_req_o.req    = 1'b1;
          obi_mgr_req_o.a.we   = 1'b0;
          obi_mgr_req_o.a.addr = src_addr_q + {25'h0, fetch_req_q, 2'b00};
        end
      end

      DSP_STORE: begin
        if (store_req_q < FFT_N && fft_result_valid) begin
          obi_mgr_req_o.req    = 1'b1;
          obi_mgr_req_o.a.we   = 1'b1;
          obi_mgr_req_o.a.addr  = dst_addr_q + {25'h0, store_req_q, 2'b00};
          obi_mgr_req_o.a.wdata = fft_result;
        end
      end

      default: ;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Interrupt -- one-cycle rising-edge pulse on DONE, gated by irq_enable
  // ---------------------------------------------------------------------------
  logic done_prev_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) done_prev_q <= 1'b0;
    else         done_prev_q <= done_q;
  end

  assign irq_o = irq_en_q & done_q & ~done_prev_q;

endmodule
