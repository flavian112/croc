// Copyright (c) 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Authors:
// - Flavian Kaufmann
// - Thanu Kanagalingam

`include "common_cells/registers.svh"

// Read-only user identification ROM.
//
// The ROM is mapped at UserBaseAddr. It returns the null-terminated chip ID
// string "FFTodile REV 1.0 - Flavian Kaufmann, Thanu Kanagalingam".
// Words are packed little-endian, i.e. word[0] byte 0 appears on rdata[7:0].

module user_rom #(
  parameter obi_pkg::obi_cfg_t ObiCfg    = croc_pkg::SbrObiCfg,
  parameter type               obi_req_t = croc_pkg::sbr_obi_req_t,
  parameter type               obi_rsp_t = croc_pkg::sbr_obi_rsp_t
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o
);

  localparam int unsigned RomWordCount = 14;
  localparam int unsigned RomIndexWidth = $clog2(RomWordCount);
  localparam int unsigned WordAddrWidth = 10; // 4 KiB ROM window / 4 bytes per word.
  localparam logic [WordAddrWidth-1:0] RomWordCountValue = RomWordCount;

  localparam logic [31:0] RomWords [RomWordCount] = '{
    32'h6F544646, // "FFTo"
    32'h656C6964, // "dile"
    32'h56455220, // " REV"
    32'h302E3120, // " 1.0"
    32'h46202D20, // " - F"
    32'h6976616C, // "lavi"
    32'h4B206E61, // "an K"
    32'h6D667561, // "aufm"
    32'h2C6E6E61, // "ann,"
    32'h61685420, // " Tha"
    32'h4B20756E, // "nu K"
    32'h67616E61, // "anag"
    32'h6E696C61, // "alin"
    32'h006D6167  // "gam\0"
  };

  logic                      req_q;
  logic                      we_q;
  logic [ObiCfg.IdWidth-1:0] id_q;
  logic [WordAddrWidth-1:0]  word_addr_q;

  `FF(req_q,       obi_req_i.req,                             '0, clk_i, rst_ni)
  `FF(we_q,        obi_req_i.a.we,                            '0, clk_i, rst_ni)
  `FF(id_q,        obi_req_i.a.aid,                           '0, clk_i, rst_ni)
  `FF(word_addr_q, obi_req_i.a.addr[WordAddrWidth+2-1:2],     '0, clk_i, rst_ni)

  logic        read_valid;
  logic [31:0] read_data;

  assign read_valid = !we_q && (word_addr_q < RomWordCountValue);
  assign read_data  = read_valid ? RomWords[word_addr_q[RomIndexWidth-1:0]] : 32'h0;

  always_comb begin
    obi_rsp_o              = '0;
    obi_rsp_o.gnt          = 1'b1;
    obi_rsp_o.rvalid       = req_q;
    obi_rsp_o.r.rid        = id_q;
    obi_rsp_o.r.rdata      = read_data;
    obi_rsp_o.r.err        = req_q & !read_valid;
    obi_rsp_o.r.r_optional = '0;
  end

endmodule
