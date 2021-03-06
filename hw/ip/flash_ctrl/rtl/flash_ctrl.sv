// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Flash Controller Module
//
//

`include "prim_assert.sv"

module flash_ctrl import flash_ctrl_pkg::*; (
  input        clk_i,
  input        rst_ni,

  // Bus Interface
  input        tlul_pkg::tl_h2d_t tl_i,
  output       tlul_pkg::tl_d2h_t tl_o,

  // Flash Interface
  input        flash_rsp_t flash_i,
  output       flash_req_t flash_o,

  // OTP Interface
  input        otp_flash_t otp_i,

  // Interrupts
  output logic intr_prog_empty_o, // Program fifo is empty
  output logic intr_prog_lvl_o,   // Program fifo is empty
  output logic intr_rd_full_o,    // Read fifo is full
  output logic intr_rd_lvl_o,     // Read fifo is full
  output logic intr_op_done_o,    // Requested flash operation (wr/erase) done
  output logic intr_op_error_o    // Requested flash operation (wr/erase) done
);

  import flash_ctrl_reg_pkg::*;

  flash_ctrl_reg2hw_t reg2hw;
  flash_ctrl_hw2reg_t hw2reg;

  tlul_pkg::tl_h2d_t tl_fifo_h2d [2];
  tlul_pkg::tl_d2h_t tl_fifo_d2h [2];

  // Register module
  flash_ctrl_reg_top u_reg (
    .clk_i,
    .rst_ni,

    .tl_i,
    .tl_o,

    .tl_win_o (tl_fifo_h2d),
    .tl_win_i (tl_fifo_d2h),

    .reg2hw,
    .hw2reg,

    .devmode_i  (1'b1)
  );

  // FIFO Connections
  logic                 prog_fifo_wvalid;
  logic                 prog_fifo_wready;
  logic                 prog_fifo_rvalid;
  logic                 prog_fifo_ren;
  logic [BusWidth-1:0]  prog_fifo_wdata;
  logic [BusWidth-1:0]  prog_fifo_rdata;
  logic [FifoDepthW-1:0] prog_fifo_depth;
  logic                 rd_fifo_wready;
  logic                 rd_fifo_rvalid;
  logic                 rd_fifo_rready;
  logic                 rd_fifo_wen;
  logic                 rd_fifo_ren;
  logic [BusWidth-1:0]  rd_fifo_wdata;
  logic [BusWidth-1:0]  rd_fifo_rdata;
  logic [FifoDepthW-1:0] rd_fifo_depth;

  // Program Control Connections
  logic prog_flash_req;
  logic prog_flash_ovfl;
  logic [BusAddrW-1:0] prog_flash_addr;
  logic prog_op_valid;

  // Read Control Connections
  logic rd_flash_req;
  logic rd_flash_ovfl;
  logic [BusAddrW-1:0] rd_flash_addr;

  // Erase Control Connections
  logic erase_flash_req;
  logic [BusAddrW-1:0] erase_flash_addr;
  logic [EraseBitWidth-1:0] erase_flash_type;

  // Done / Error signaling from ctrl modules
  logic prog_done, rd_done, erase_done;
  logic prog_err, rd_err, erase_err;

  // Flash Memory Protection Connections
  logic [BusAddrW-1:0] flash_addr;
  logic flash_req;
  logic flash_rd_done, flash_prog_done, flash_erase_done;
  logic flash_error;
  logic [BusWidth-1:0] flash_prog_data;
  logic flash_prog_last;
  logic [BusWidth-1:0] flash_rd_data;
  logic flash_phy_busy;
  logic rd_op;
  logic prog_op;
  logic erase_op;
  logic [AllPagesW-1:0] err_page;
  logic [BankW-1:0] err_bank;

  // Flash control arbitration connections to hardware interface
  flash_ctrl_reg2hw_control_reg_t hw_ctrl;
  logic hw_req;
  logic [BusAddrW-1:0] hw_addr;
  logic hw_done;
  logic hw_err;
  logic hw_rvalid;
  logic hw_rready;
  flash_sel_e if_sel;
  logic sw_sel;

  // Flash control arbitration connections to software interface
  logic sw_ctrl_done;
  logic sw_ctrl_err;

  // Flash control muxed connections
  flash_ctrl_reg2hw_control_reg_t muxed_ctrl;
  logic [31:0] muxed_addr;
  logic op_start;
  logic [11:0] op_num_words;
  logic [BusAddrW-1:0] op_addr;
  flash_op_e op_type;
  flash_part_e op_part;
  logic [EraseBitWidth-1:0] op_erase_type;

  logic ctrl_init_busy;
  logic fifo_clr;

  // software tlul to flash control aribration
  logic sw_rvalid;
  logic adapter_rvalid;
  logic sw_wvalid;
  logic sw_wen;
  logic sw_wready;

  // flash control arbitration between softawre / harware interfaces
  flash_ctrl_arb u_ctrl_arb (
    .clk_i,
    .rst_ni,

    // software interface to rd_ctrl / erase_ctrl
    .sw_ctrl_i(reg2hw.control),
    .sw_addr_i(reg2hw.addr.q),
    .sw_ack_o(sw_ctrl_done),
    .sw_err_o(sw_ctrl_err),

    // software interface to rd_fifo
    .sw_rvalid_o(sw_rvalid),
    .sw_rready_i(adapter_rvalid),

    // software interface to prog_fifo
    .sw_wvalid_i(sw_wvalid & sw_wen),
    .sw_wready_o(sw_wready),

    // hardware interface to rd_ctrl / erase_ctrl
    .hw_req_i(hw_req),
    .hw_ctrl_i(hw_ctrl),
    .hw_addr_i(top_pkg::TL_AW'(hw_addr)),
    .hw_ack_o(hw_done),
    .hw_err_o(hw_err),

    // hardware interface to rd_fifo
    .hw_rvalid_o(hw_rvalid),
    .hw_rready_i(hw_rready),

    // hardware interface does not talk to prog_fifo

    // muxed interface to rd_ctrl / erase_ctrl
    .muxed_ctrl_o(muxed_ctrl),
    .muxed_addr_o(muxed_addr),
    .prog_ack_i(prog_done),
    .prog_err_i(prog_err),
    .rd_ack_i(rd_done),
    .rd_err_i(rd_err),
    .erase_ack_i(erase_done),
    .erase_err_i(erase_err),

    // muxed interface to rd_fifo
    .rd_fifo_rvalid_i(rd_fifo_rvalid),
    .rd_fifo_rready_o(rd_fifo_rready),

    // muxed interface to prog_fifo
    .prog_fifo_wvalid_o(prog_fifo_wvalid),
    .prog_fifo_wready_i(prog_fifo_wready),

    // flash phy initilization ongoing
    .flash_phy_busy_i(flash_phy_busy),

    // clear fifos
    .fifo_clr_o(fifo_clr),

    // indication that sw has been selected
    .sel_o(if_sel)
  );

  assign op_start      = muxed_ctrl.start.q;
  assign op_num_words  = muxed_ctrl.num.q;
  assign op_erase_type = muxed_ctrl.erase_sel.q;
  assign op_addr       = muxed_addr[BusByteWidth +: BusAddrW];
  assign op_type       = flash_op_e'(muxed_ctrl.op.q);
  assign op_part       = flash_part_e'(muxed_ctrl.partition_sel.q);
  assign rd_op         = op_type == FlashOpRead;
  assign prog_op       = op_type == FlashOpProgram;
  assign erase_op      = op_type == FlashOpErase;
  assign sw_sel        = if_sel == SwSel;

  // hardware interface
  flash_ctrl_lcmgr u_flash_hw_if (
    .clk_i,
    .rst_ni,

    // interface to ctrl arb control ports
    .ctrl_o(hw_ctrl),
    .req_o(hw_req),
    .addr_o(hw_addr),
    .done_i(hw_done),
    .err_i(hw_err),

    // interface to ctrl_arb data ports
    .rready_o(hw_rready),
    .rvalid_i(hw_rvalid),

    // direct form rd_fifo
    .rdata_i(rd_fifo_rdata),

    // external rma request
    .rma_i('0),
    .rma_token_i('0), // just a random string
    .rma_token_o(),
    .rma_rsp_o(),

    // random value
    .rand_i('0),

    // outgoing seeds
    .seeds_o(),

    // init ongoing
    .init_busy_o(ctrl_init_busy)
  );

  // Program FIFO
  // Since the program and read FIFOs are never used at the same time, it should really be one
  // FIFO with muxed inputs and outputs.  This should be addressed once the flash integration
  // strategy has been identified
  assign prog_op_valid = op_start & prog_op;

  tlul_adapter_sram #(
    .SramAw(1),         //address unused
    .SramDw(BusWidth),
    .ByteAccess(0),     //flash may not support byte access
    .ErrOnRead(1)       //reads not supported
  ) u_to_prog_fifo (
    .clk_i,
    .rst_ni,
    .tl_i       (tl_fifo_h2d[0]),
    .tl_o       (tl_fifo_d2h[0]),
    .req_o      (sw_wvalid),
    .gnt_i      (sw_wready),
    .we_o       (sw_wen),
    .addr_o     (),
    .wmask_o    (),
    .wdata_o    (prog_fifo_wdata),
    .rdata_i    (BusWidth'(0)),
    .rvalid_i   (1'b0),
    .rerror_i   (2'b0)
  );

  prim_fifo_sync #(
    .Width(BusWidth),
    .Depth(FifoDepth)
  ) u_prog_fifo (
    .clk_i,
    .rst_ni,
    .clr_i   (reg2hw.fifo_rst.q | fifo_clr),
    .wvalid_i(prog_fifo_wvalid & prog_op_valid),
    .wready_o(prog_fifo_wready),
    .wdata_i (prog_fifo_wdata),
    .depth_o (prog_fifo_depth),
    .rvalid_o(prog_fifo_rvalid),
    .rready_i(prog_fifo_ren),
    .rdata_o (prog_fifo_rdata)
  );

  // Program handler is consumer of prog_fifo
  flash_prog_ctrl #(
    .DataW(BusWidth),
    .AddrW(BusAddrW)
  ) u_flash_prog_ctrl (
    .clk_i,
    .rst_ni,

    // Software Interface
    .op_start_i     (prog_op_valid),
    .op_num_words_i (op_num_words),
    .op_done_o      (prog_done),
    .op_err_o       (prog_err),
    .op_addr_i      (op_addr),

    // FIFO Interface
    .data_i         (prog_fifo_rdata),
    .data_rdy_i     (prog_fifo_rvalid),
    .data_rd_o      (prog_fifo_ren),

    // Flash Macro Interface
    .flash_req_o    (prog_flash_req),
    .flash_addr_o   (prog_flash_addr),
    .flash_ovfl_o   (prog_flash_ovfl),
    .flash_data_o   (flash_prog_data),
    .flash_last_o   (flash_prog_last),
    .flash_done_i   (flash_prog_done),
    .flash_error_i  (flash_error)
  );

  // Read FIFO


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      adapter_rvalid <= 1'b0;
    end else begin
      adapter_rvalid <= rd_fifo_ren && sw_rvalid;
    end
  end

  // tlul adapter represents software's access interface to flash
  tlul_adapter_sram #(
    .SramAw(1),         //address unused
    .SramDw(BusWidth),
    .ByteAccess(0),     //flash may not support byte access
    .ErrOnWrite(1)      //writes not supported
  ) u_to_rd_fifo (
    .clk_i,
    .rst_ni,
    .tl_i       (tl_fifo_h2d[1]),
    .tl_o       (tl_fifo_d2h[1]),
    .req_o      (rd_fifo_ren),
    .gnt_i      (rd_fifo_rvalid),
    .we_o       (),
    .addr_o     (),
    .wmask_o    (),
    .wdata_o    (),
    .rdata_i    (rd_fifo_rdata),
    .rvalid_i   (adapter_rvalid),
    .rerror_i   (2'b0)
  );

  prim_fifo_sync #(
    .Width(BusWidth),
    .Depth(FifoDepth)
  ) u_rd_fifo (
    .clk_i,
    .rst_ni,
    .clr_i   (reg2hw.fifo_rst.q | fifo_clr),
    .wvalid_i(rd_fifo_wen),
    .wready_o(rd_fifo_wready),
    .wdata_i (rd_fifo_wdata),
    .depth_o (rd_fifo_depth),
    .rvalid_o(rd_fifo_rvalid),
    .rready_i(rd_fifo_rready),
    .rdata_o (rd_fifo_rdata)
  );

  // Read handler is consumer of rd_fifo
  flash_rd_ctrl #(
    .DataW(BusWidth),
    .AddrW(BusAddrW)
  ) u_flash_rd_ctrl (
    .clk_i,
    .rst_ni,

    // To arbiter Interface
    .op_start_i     (op_start & rd_op),
    .op_num_words_i (op_num_words),
    .op_done_o      (rd_done),
    .op_err_o       (rd_err),
    .op_addr_i      (op_addr),

    // FIFO Interface
    .data_rdy_i     (rd_fifo_wready),
    .data_o         (rd_fifo_wdata),
    .data_wr_o      (rd_fifo_wen),

    // Flash Macro Interface
    .flash_req_o    (rd_flash_req),
    .flash_addr_o   (rd_flash_addr),
    .flash_ovfl_o   (rd_flash_ovfl),
    .flash_data_i   (flash_rd_data),
    .flash_done_i   (flash_rd_done),
    .flash_error_i  (flash_error)
  );

  // Erase handler does not consume fifo
  flash_erase_ctrl #(
    .AddrW(BusAddrW),
    .PagesPerBank(PagesPerBank),
    .WordsPerPage(BusWordsPerPage),
    .EraseBitWidth(EraseBitWidth)
  ) u_flash_erase_ctrl (
    // Software Interface
    .op_start_i     (op_start & erase_op),
    .op_type_i      (op_erase_type),
    .op_done_o      (erase_done),
    .op_err_o       (erase_err),
    .op_addr_i      (op_addr),

    // Flash Macro Interface
    .flash_req_o    (erase_flash_req),
    .flash_addr_o   (erase_flash_addr),
    .flash_op_o     (erase_flash_type),
    .flash_done_i   (flash_erase_done),
    .flash_error_i  (flash_error)
  );

  // Final muxing to flash macro module
  always_comb begin
    unique case (op_type)
      FlashOpRead: begin
        flash_req = rd_flash_req;
        flash_addr = rd_flash_addr;
      end
      FlashOpProgram: begin
        flash_req = prog_flash_req;
        flash_addr = prog_flash_addr;
      end
      FlashOpErase: begin
        flash_req = erase_flash_req;
        flash_addr = erase_flash_addr;
      end
      default: begin
        flash_req = 1'b0;
        flash_addr  = '0;
      end
    endcase // unique case (op_type)
  end

  // extra region is the default region
  flash_ctrl_reg2hw_mp_region_cfg_mreg_t [MpRegions:0] region_cfgs;
  assign region_cfgs[MpRegions-1:0] = reg2hw.mp_region_cfg[MpRegions-1:0];

  //default region
  assign region_cfgs[MpRegions].base.q = '0;
  assign region_cfgs[MpRegions].size.q = NumBanks * PagesPerBank;
  assign region_cfgs[MpRegions].en.q = 1'b1;
  assign region_cfgs[MpRegions].rd_en.q = reg2hw.default_region.rd_en.q;
  assign region_cfgs[MpRegions].prog_en.q = reg2hw.default_region.prog_en.q;
  assign region_cfgs[MpRegions].erase_en.q = reg2hw.default_region.erase_en.q;
  // we are allowed to set default accessibility of data partitions
  // however info partitions default to inaccessible
  assign region_cfgs[MpRegions].partition.q = FlashPartData;

  // direct assignment since prog/rd/erase_ctrl do not make use of op_part
  flash_part_e flash_part_sel;
  assign flash_part_sel = op_part;

  // Flash memory protection
  // Memory protection is page based and thus should use phy addressing
  // This should move to flash_phy long term
  flash_mp #(
    .MpRegions(MpRegions),
    .NumBanks(NumBanks),
    .AllPagesW(AllPagesW)
  ) u_flash_mp (
    .clk_i,
    .rst_ni,

    // arbiter interface selection
    .if_sel_i(if_sel),

    // sw configuration
    .region_cfgs_i(region_cfgs),
    .bank_cfgs_i(reg2hw.mp_bank_cfg),

    // read / prog / erase controls
    .req_i(flash_req),
    .req_addr_i(flash_addr[BusAddrW-1 -: AllPagesW]),
    .req_part_i(flash_part_sel),
    .addr_ovfl_i(rd_flash_ovfl | prog_flash_ovfl),
    .req_bk_i(flash_addr[BusAddrW-1 -: BankW]),
    .rd_i(rd_op),
    .prog_i(prog_op),
    .pg_erase_i(erase_op & (erase_flash_type == FlashErasePage)),
    .bk_erase_i(erase_op & (erase_flash_type == FlashEraseBank)),
    .rd_done_o(flash_rd_done),
    .prog_done_o(flash_prog_done),
    .erase_done_o(flash_erase_done),
    .error_o(flash_error),
    .err_addr_o(err_page),
    .err_bank_o(err_bank),

    // flash phy interface
    .req_o(flash_o.req),
    .rd_o(flash_o.rd),
    .prog_o(flash_o.prog),
    .pg_erase_o(flash_o.pg_erase),
    .bk_erase_o(flash_o.bk_erase),
    .rd_done_i(flash_i.rd_done),
    .prog_done_i(flash_i.prog_done),
    .erase_done_i(flash_i.erase_done)
  );


  // software interface feedback
  // most values (other than flash_phy_busy) should only update when software operations
  // are actually selected
  assign hw2reg.op_status.done.d     = 1'b1;
  assign hw2reg.op_status.done.de    = sw_ctrl_done;
  assign hw2reg.op_status.err.d      = 1'b1;
  assign hw2reg.op_status.err.de     = sw_ctrl_err;
  assign hw2reg.status.rd_full.d     = ~rd_fifo_wready;
  assign hw2reg.status.rd_full.de    = sw_sel;
  assign hw2reg.status.rd_empty.d    = ~rd_fifo_rvalid;
  assign hw2reg.status.rd_empty.de   = sw_sel;
  assign hw2reg.status.prog_full.d   = ~prog_fifo_wready;
  assign hw2reg.status.prog_full.de  = sw_sel;
  assign hw2reg.status.prog_empty.d  = ~prog_fifo_rvalid;
  assign hw2reg.status.prog_empty.de = sw_sel;
  assign hw2reg.status.init_wip.d    = flash_phy_busy | ctrl_init_busy;
  assign hw2reg.status.init_wip.de   = 1'b1;
  assign hw2reg.status.error_page.d  = err_page;
  assign hw2reg.status.error_page.de = sw_sel;
  assign hw2reg.status.error_bank.d  = err_bank;
  assign hw2reg.status.error_bank.de = sw_sel;
  assign hw2reg.control.start.d      = 1'b0;
  assign hw2reg.control.start.de     = sw_ctrl_done;
  // if software operation selected, based on transaction start
  // if software operation not selected, software is free to change contents
  assign hw2reg.ctrl_regwen.d        = sw_sel ? !op_start : 1'b1;

  // Flash Interface
  assign flash_o.addr = flash_addr;
  assign flash_o.part = flash_part_sel;
  assign flash_o.prog_data = flash_prog_data;
  assign flash_o.prog_last = flash_prog_last;
  assign flash_o.scramble_en = reg2hw.scramble_en.q;
  assign flash_o.addr_key = otp_i.addr_key;
  assign flash_o.data_key = otp_i.data_key;
  assign flash_rd_data = flash_i.rd_data;
  assign flash_phy_busy = flash_i.init_busy;

  // Interrupts
  // Generate edge triggered signals for sources that are level
  logic [3:0] intr_src;
  logic [3:0] intr_src_q;
  logic [3:0] intr_assert;

  assign intr_src = { ~prog_fifo_rvalid,
                      reg2hw.fifo_lvl.prog.q == prog_fifo_depth,
                      ~rd_fifo_wready,
                      reg2hw.fifo_lvl.rd.q == rd_fifo_depth
                    };

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      intr_src_q <= 4'h8; //prog_fifo is empty by default
    end else if (sw_sel) begin
      intr_src_q <= intr_src;
    end
  end

  assign intr_assert = ~intr_src_q & intr_src;


  assign intr_prog_empty_o = reg2hw.intr_enable.prog_empty.q & reg2hw.intr_state.prog_empty.q;
  assign intr_prog_lvl_o = reg2hw.intr_enable.prog_lvl.q & reg2hw.intr_state.prog_lvl.q;
  assign intr_rd_full_o = reg2hw.intr_enable.rd_full.q & reg2hw.intr_state.rd_full.q;
  assign intr_rd_lvl_o = reg2hw.intr_enable.rd_lvl.q & reg2hw.intr_state.rd_lvl.q;
  assign intr_op_done_o = reg2hw.intr_enable.op_done.q & reg2hw.intr_state.op_done.q;
  assign intr_op_error_o = reg2hw.intr_enable.op_error.q & reg2hw.intr_state.op_error.q;

  assign hw2reg.intr_state.prog_empty.d  = 1'b1;
  assign hw2reg.intr_state.prog_empty.de = intr_assert[3]  |
                                           (reg2hw.intr_test.prog_empty.qe  &
                                           reg2hw.intr_test.prog_empty.q);

  assign hw2reg.intr_state.prog_lvl.d  = 1'b1;
  assign hw2reg.intr_state.prog_lvl.de = intr_assert[2]  |
                                         (reg2hw.intr_test.prog_lvl.qe  &
                                         reg2hw.intr_test.prog_lvl.q);

  assign hw2reg.intr_state.rd_full.d  = 1'b1;
  assign hw2reg.intr_state.rd_full.de = intr_assert[1] |
                                        (reg2hw.intr_test.rd_full.qe  &
                                        reg2hw.intr_test.rd_full.q);

  assign hw2reg.intr_state.rd_lvl.d  = 1'b1;
  assign hw2reg.intr_state.rd_lvl.de =  intr_assert[0] |
                                       (reg2hw.intr_test.rd_lvl.qe  &
                                       reg2hw.intr_test.rd_lvl.q);


  assign hw2reg.intr_state.op_done.d  = 1'b1;
  assign hw2reg.intr_state.op_done.de = sw_ctrl_done  |
                                        (reg2hw.intr_test.op_done.qe  &
                                        reg2hw.intr_test.op_done.q);

  assign hw2reg.intr_state.op_error.d  = 1'b1;
  assign hw2reg.intr_state.op_error.de = sw_ctrl_err  |
                                        (reg2hw.intr_test.op_error.qe  &
                                        reg2hw.intr_test.op_error.q);



  // Unused bits
  logic [BusByteWidth-1:0] unused_byte_sel;
  logic [31-BusAddrW:0] unused_higher_addr_bits;
  logic [31:0] unused_scratch;


  // Unused signals
  assign unused_byte_sel = muxed_addr[BusByteWidth-1:0];
  assign unused_higher_addr_bits = muxed_addr[31:BusAddrW];
  assign unused_scratch = reg2hw.scratch;


  // Assertions

  `ASSERT_KNOWN(TlDValidKnownO_A,       tl_o.d_valid     )
  `ASSERT_KNOWN(TlAReadyKnownO_A,       tl_o.a_ready     )
  `ASSERT_KNOWN(FlashKnownO_A,          {flash_o.req, flash_o.rd, flash_o.prog, flash_o.pg_erase,
                                         flash_o.bk_erase})
  `ASSERT_KNOWN_IF(FlashAddrKnown_A,    flash_o.addr, flash_o.req)
  `ASSERT_KNOWN_IF(FlashProgKnown_A,    flash_o.prog_data, flash_o.prog & flash_o.req)
  `ASSERT_KNOWN(IntrProgEmptyKnownO_A,  intr_prog_empty_o)
  `ASSERT_KNOWN(IntrProgLvlKnownO_A,    intr_prog_lvl_o  )
  `ASSERT_KNOWN(IntrProgRdFullKnownO_A, intr_rd_full_o   )
  `ASSERT_KNOWN(IntrRdLvlKnownO_A,      intr_rd_lvl_o    )
  `ASSERT_KNOWN(IntrOpDoneKnownO_A,     intr_op_done_o   )
  `ASSERT_KNOWN(IntrOpErrorKnownO_A,    intr_op_error_o  )

endmodule
