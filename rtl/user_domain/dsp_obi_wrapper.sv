// 64-point fixed-point FFT accelerator for the Croc SoC user domain.
//
// Uses the pre-generated ZipCPU dblclockfft core (fftmain.v, LGPL v3).
// Generated with: fftgen -f 64 -n 16 -1 -d rtl/user_domain/fft_core/
//   IWIDTH = 16 (16 bits per component in), OWIDTH = 20 (20 bits per component out)
//
// Register map (byte addresses relative to base, i.e. relative to UserBaseAddr = 0x2000_0000):
//   +0x00  CTRL      [0]=START (self-clearing write-only)
//   +0x04  STATUS    [0]=BUSY, [1]=DONE
//   +0x08  SRC_ADDR  32-bit source address for 64 packed complex samples
//   +0x0C  DST_ADDR  32-bit destination address for 64 packed FFT outputs
//   +0x10  IRQ_CTRL  [0]=irq_enable
//
// Data format: each 32-bit word = {real[15:0], imag[15:0]}
//   Input : 64 words at SRC_ADDR  (256 bytes)
//   Output: 64 words at DST_ADDR  (256 bytes), truncated from 20-bit to 16-bit per component
//
// OBI subordinate: control registers, always clocked on clk_i (not gated).
// OBI manager    : DMA port — reads inputs from SRAM (FETCH), writes outputs to SRAM (STORE).
//                  FETCH and STORE never overlap (different FSM states).
//
// Clock gating: tc_clk_gating gates the ZipCPU FFT core clock when not busy.
//
// NOTE: The STORE phase assumes OBI gnt=1 every cycle (valid for Croc SoC SRAM memories).
//       If gnt=0, fft_ce is de-asserted to stall the pipeline until the write is accepted.

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
  // FFT parameters — must match the generated fftmain.v
  // ---------------------------------------------------------------------------
  localparam int unsigned IWIDTH = 16;
  localparam int unsigned OWIDTH = 20;
  localparam int unsigned FFT_N  = 64;

  // ---------------------------------------------------------------------------
  // FSM states
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    DSP_IDLE,       // waiting for START
    DSP_RST,        // one-cycle reset pulse to ZipCPU pipeline
    DSP_FETCH,      // issue 64 OBI reads, feed samples into FFT
    DSP_WAIT_SYNC,  // drain pipeline until o_sync fires
    DSP_STORE       // issue 64 OBI writes with FFT output
  } dsp_state_e;

  dsp_state_e state_q, state_d;

  // Counters: 9-bit, holding values 0..FFT_N (max 64, fits in 7 bits — 9 for safety)
  logic [8:0] fetch_req_q;   // OBI read requests issued
  logic [8:0] fetch_rsp_q;   // OBI read responses received
  logic [8:0] store_req_q;   // OBI write requests issued
  logic [8:0] store_rsp_q;   // OBI write responses received

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
  // OBI Subordinate — register bank (always on clk_i, not gated)
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
  // FSM — next-state logic (combinatorial)
  // ---------------------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      DSP_IDLE:      if (start_pulse)                                          state_d = DSP_RST;
      DSP_RST:                                                                 state_d = DSP_FETCH;
      DSP_FETCH:     if (fetch_rsp_q == (FFT_N-1) && obi_mgr_rsp_i.rvalid) state_d = DSP_WAIT_SYNC;
      DSP_WAIT_SYNC: if (fft_sync)                                           state_d = DSP_STORE;
      DSP_STORE:     if (store_rsp_q == (FFT_N-1) && obi_mgr_rsp_i.rvalid) state_d = DSP_IDLE;
      default:                                                                  state_d = DSP_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // FSM — registered state and counters
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

        DSP_RST: ; // one-cycle stall while ZipCPU resets

        DSP_FETCH: begin
          // Count accepted read requests
          if (obi_mgr_rsp_i.gnt && (fetch_req_q < FFT_N))
            fetch_req_q <= fetch_req_q + 9'd1;
          // Count read responses; each rvalid feeds one sample into FFT
          if (obi_mgr_rsp_i.rvalid && (fetch_rsp_q < FFT_N))
            fetch_rsp_q <= fetch_rsp_q + 9'd1;
        end

        DSP_WAIT_SYNC: ; // waiting for o_sync from ZipCPU

        DSP_STORE: begin
          // Count accepted write requests
          if (obi_mgr_rsp_i.gnt && (store_req_q < FFT_N))
            store_req_q <= store_req_q + 9'd1;
          // Count write acks
          if (obi_mgr_rsp_i.rvalid && (store_rsp_q < FFT_N))
            store_rsp_q <= store_rsp_q + 9'd1;
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
  // ZipCPU FFT core signals
  // ---------------------------------------------------------------------------
  logic                        fft_clk;
  logic                        fft_reset;
  logic                        fft_ce;
  logic [2*IWIDTH-1:0]         fft_sample;
  logic [2*OWIDTH-1:0]         fft_result;
  logic                        fft_sync;

  // Clock gate: FFT core only receives clock ticks when busy.
  // IS_FUNCTIONAL=1 ensures the gate is not optimised away during synthesis.
  tc_clk_gating #(
    .IS_FUNCTIONAL ( 1'b1 )
  ) i_fft_clk_gate (
    .clk_i     ( clk_i      ),
    .en_i      ( busy_q     ),
    .test_en_i ( testmode_i ),
    .clk_o     ( fft_clk    )
  );

  // Synchronous active-high reset for one cycle at the start of each computation
  assign fft_reset = (state_q == DSP_RST);

  // Clock enable:
  //  - FETCH:      one ce per valid read response (one sample per rvalid)
  //  - WAIT_SYNC:  always 1 to drain pipeline, but STOP on the cycle fft_sync fires
  //                (that cycle fft_result already holds sample 0; don't advance it)
  //  - STORE:      gated by gnt — stall pipeline if write is back-pressured
  assign fft_ce = ((state_q == DSP_FETCH)      &  obi_mgr_rsp_i.rvalid)
                | ((state_q == DSP_WAIT_SYNC)   & !fft_sync)
                | ((state_q == DSP_STORE)        & (store_req_q < FFT_N) & obi_mgr_rsp_i.gnt);

  // FFT input: packed {real[15:0], imag[15:0]} word read from SRAM
  assign fft_sample = (state_q == DSP_FETCH) ? obi_mgr_rsp_i.r.rdata : '0;

  // ---------------------------------------------------------------------------
  // ZipCPU fftmain instantiation (pre-generated, committed to fft_core/)
  // ---------------------------------------------------------------------------
  fftmain i_fftmain (
    .i_clk    ( fft_clk    ),
    .i_reset  ( fft_reset  ),
    .i_ce     ( fft_ce     ),
    .i_sample ( fft_sample ),
    .o_result ( fft_result ),
    .o_sync   ( fft_sync   )
  );

  // ---------------------------------------------------------------------------
  // OBI Manager — DMA reads (FETCH) and writes (STORE)
  // ---------------------------------------------------------------------------
  // Output truncation: OWIDTH=20 → 16 bits, keep the most significant bits.
  //   o_result[39:20] = real[19:0],  top 16 bits = o_result[39:24]
  //   o_result[19:0]  = imag[19:0],  top 16 bits = o_result[19:4]
  //   wdata = {real[15:0], imag[15:0]} = {o_result[39:24], o_result[19:4]}
  logic [31:0] fft_result_truncated;
  assign fft_result_truncated = {fft_result[39:24], fft_result[19:4]};

  always_comb begin
    obi_mgr_req_o         = '0;
    obi_mgr_req_o.a.be    = 4'hF;   // full 32-bit word access

    unique case (state_q)
      DSP_FETCH: begin
        if (fetch_req_q < FFT_N) begin
          obi_mgr_req_o.req    = 1'b1;
          obi_mgr_req_o.a.we   = 1'b0;
          obi_mgr_req_o.a.addr = src_addr_q + {fetch_req_q[7:0], 2'b00};
        end
      end

      DSP_STORE: begin
        if (store_req_q < FFT_N) begin
          obi_mgr_req_o.req    = 1'b1;
          obi_mgr_req_o.a.we   = 1'b1;
          obi_mgr_req_o.a.addr  = dst_addr_q + {store_req_q[7:0], 2'b00};
          obi_mgr_req_o.a.wdata = fft_result_truncated;
        end
      end

      default: ;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Interrupt — one-cycle rising-edge pulse on DONE, gated by irq_enable
  // ---------------------------------------------------------------------------
  logic done_prev_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) done_prev_q <= 1'b0;
    else         done_prev_q <= done_q;
  end

  assign irq_o = irq_en_q & done_q & ~done_prev_q;

endmodule
