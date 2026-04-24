// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

`include "common_cells/registers.svh"

/// User ROM: null-terminated chip identification string.
/// Mapped at UserBaseAddr (0x2000_0000), within a 4KB window.
/// Content: "CrocFFT v1 - Flavian Kaufmann, Thanu Kanagalingam"
module user_rom #(
    parameter obi_pkg::obi_cfg_t ObiCfg   = croc_pkg::SbrObiCfg,
    parameter type               obi_req_t = croc_pkg::sbr_obi_req_t,
    parameter type               obi_rsp_t = croc_pkg::sbr_obi_rsp_t
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    input  obi_req_t obi_req_i,
    output obi_rsp_t obi_rsp_o
);

    // "CrocFFT v1 - Flavian Kaufmann, Thanu Kanagalingam\0" -- 49 chars + null = 50 bytes = 13 words
    // Encoding: word[i] = { byte[4i+3], byte[4i+2], byte[4i+1], byte[4i] } (little-endian)
    localparam int unsigned WordAddrBits = 4; // 4 bits covers up to 16 words (> 13)

    logic                        req_d,       req_q;
    logic                        we_d,        we_q;
    logic [ObiCfg.IdWidth-1:0]   id_d,        id_q;
    logic [WordAddrBits-1:0]     word_addr_d, word_addr_q;

    assign req_d       = obi_req_i.req;
    assign we_d        = obi_req_i.a.we;
    assign id_d        = obi_req_i.a.aid;
    assign word_addr_d = obi_req_i.a.addr[WordAddrBits+2-1:2];

    `FF(req_q,       req_d,       '0, clk_i, rst_ni)
    `FF(we_q,        we_d,        '0, clk_i, rst_ni)
    `FF(id_q,        id_d,        '0, clk_i, rst_ni)
    `FF(word_addr_q, word_addr_d, '0, clk_i, rst_ni)

    logic        rom_err;
    logic [31:0] rom_rdata;

    always_comb begin
        rom_rdata = 32'h0;
        rom_err   = 1'b1;
        if (!we_q) begin
            case (word_addr_q)
                4'd0: begin rom_rdata = 32'h636F7243; rom_err = 1'b0; end // "Croc"
                4'd1: begin rom_rdata = 32'h20544646; rom_err = 1'b0; end // "FFT "
                4'd2: begin rom_rdata = 32'h2D203176; rom_err = 1'b0; end // "v1 -"
                4'd3: begin rom_rdata = 32'h616C4620; rom_err = 1'b0; end // " Fla"
                4'd4: begin rom_rdata = 32'h6E616976; rom_err = 1'b0; end // "vian"
                4'd5: begin rom_rdata = 32'h75614B20; rom_err = 1'b0; end // " Kau"
                4'd6: begin rom_rdata = 32'h6E616D66; rom_err = 1'b0; end // "fman"
                4'd7: begin rom_rdata = 32'h54202C6E; rom_err = 1'b0; end // "n, T"
                4'd8: begin rom_rdata = 32'h756E6168; rom_err = 1'b0; end // "hanu"
                4'd9: begin rom_rdata = 32'h6E614B20; rom_err = 1'b0; end // " Kan"
                4'd10: begin rom_rdata = 32'h6C616761; rom_err = 1'b0; end // "agal"
                4'd11: begin rom_rdata = 32'h61676E69; rom_err = 1'b0; end // "inga"
                4'd12: begin rom_rdata = 32'h0000006D; rom_err = 1'b0; end // "m\0"
                default: begin rom_rdata = 32'h0; rom_err = 1'b1; end
            endcase
        end
    end

    always_comb begin
        obi_rsp_o         = '0;
        obi_rsp_o.gnt     = 1'b1;
        obi_rsp_o.rvalid  = req_q;
        obi_rsp_o.r.rid   = id_q;
        obi_rsp_o.r.rdata = rom_rdata;
        obi_rsp_o.r.err   = rom_err;
    end

endmodule
