//
// Copyright 2016 Ettus Research
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//

module noc_block_ddc_1_to_n #(
  parameter NOC_ID            = 64'hDDC0_1020_1234_5678,
  parameter STR_SINK_FIFOSIZE = 11,     //Log2 of input buffer size in 8-byte words (must hold at least 2 MTU packets)
  parameter MTU               = 10,     //Log2 of output buffer size in 8-byte words (must hold at least 1 MTU packet)
  parameter NUM_CHAINS        = 2,
  parameter COMPAT_NUM_MAJOR  = 32'h2,
  parameter COMPAT_NUM_MINOR  = 32'h0,
  parameter NUM_HB            = 3,
  parameter CIC_MAX_DECIM     = 32
)(
  input bus_clk, input bus_rst,
  input ce_clk, input ce_rst,
  input  [63:0] i_tdata, input  i_tlast, input  i_tvalid, output i_tready,
  output [63:0] o_tdata, output o_tlast, output o_tvalid, input  o_tready,
  output [63:0] debug
);

  ////////////////////////////////////////////////////////////
  //
  // RFNoC Shell
  //
  ////////////////////////////////////////////////////////////
  wire [NUM_CHAINS*32-1:0]      set_data;
  wire [NUM_CHAINS*8-1:0]       set_addr;
  wire [NUM_CHAINS-1:0]         set_stb;
  wire [NUM_CHAINS*64-1:0]      set_time;
  wire [NUM_CHAINS-1:0]         set_has_time;
  wire [NUM_CHAINS-1:0]         rb_stb;
  wire [8*NUM_CHAINS-1:0]       rb_addr;
  reg [64*NUM_CHAINS-1:0]       rb_data;

  wire [63:0]                   cmdout_tdata, ackin_tdata;
  wire                          cmdout_tlast, cmdout_tvalid, cmdout_tready, ackin_tlast, ackin_tvalid, ackin_tready;

  wire [64*NUM_CHAINS-1:0]      str_sink_tdata, str_src_tdata;
  wire [NUM_CHAINS-1:0]         str_sink_tlast, str_sink_tvalid, str_sink_tready, str_src_tlast, str_src_tvalid, str_src_tready;

  wire [NUM_CHAINS-1:0]         clear_tx_seqnum;
  wire [16*NUM_CHAINS-1:0]      src_sid, next_dst_sid, resp_in_dst_sid, resp_out_dst_sid;

  // TODO: Only populate FIRST port with a FIFO (other ports unused)
  noc_shell #(
    .NOC_ID(NOC_ID),
    .INPUT_PORTS(NUM_CHAINS),
    .OUTPUT_PORTS(NUM_CHAINS),
    .STR_SINK_FIFOSIZE({NUM_CHAINS{STR_SINK_FIFOSIZE[7:0]}}),
    .MTU({NUM_CHAINS{MTU[7:0]}}))
  noc_shell (
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .i_tdata(i_tdata), .i_tlast(i_tlast), .i_tvalid(i_tvalid), .i_tready(i_tready),
    .o_tdata(o_tdata), .o_tlast(o_tlast), .o_tvalid(o_tvalid), .o_tready(o_tready),
    // Computer Engine Clock Domain
    .clk(ce_clk), .reset(ce_rst),
    // Control Sink
    .set_data(set_data), .set_addr(set_addr), .set_stb(set_stb), .set_time(set_time), .set_has_time(set_has_time),
    .rb_stb(rb_stb), .rb_data(rb_data), .rb_addr(rb_addr),
    // Control Source
    .cmdout_tdata(cmdout_tdata), .cmdout_tlast(cmdout_tlast), .cmdout_tvalid(cmdout_tvalid), .cmdout_tready(cmdout_tready),
    .ackin_tdata(ackin_tdata), .ackin_tlast(ackin_tlast), .ackin_tvalid(ackin_tvalid), .ackin_tready(ackin_tready),
    // Stream Sink
    .str_sink_tdata(str_sink_tdata), .str_sink_tlast(str_sink_tlast), .str_sink_tvalid(str_sink_tvalid), .str_sink_tready(str_sink_tready),
    // Stream Source
    .str_src_tdata(str_src_tdata), .str_src_tlast(str_src_tlast), .str_src_tvalid(str_src_tvalid), .str_src_tready(str_src_tready),
    // Stream IDs set by host
    .src_sid(src_sid),                   // SID of this block
    .next_dst_sid(next_dst_sid),         // Next destination SID
    .resp_in_dst_sid(resp_in_dst_sid),   // Response destination SID for input stream responses / errors
    .resp_out_dst_sid(resp_out_dst_sid), // Response destination SID for output stream responses / errors
    // Misc
    .vita_time(64'd0),
    .clear_tx_seqnum(clear_tx_seqnum),
    .debug(debug));

  // Control Source Unused
  assign cmdout_tdata = 64'd0;
  assign cmdout_tlast = 1'b0;
  assign cmdout_tvalid = 1'b0;
  assign ackin_tready = 1'b1;

  // NoC Shell registers 0 - 127,
  // User register address space starts at 128
  localparam SR_N_ADDR        = 128;
  localparam SR_M_ADDR        = 129;
  localparam SR_CONFIG_ADDR   = 130;
  localparam SR_FREQ_ADDR     = 132;
  localparam SR_SCALE_IQ_ADDR = 133;
  localparam SR_DECIM_ADDR    = 134;
  localparam SR_MUX_ADDR      = 135;
  localparam SR_COEFFS_ADDR   = 136;
  localparam RB_COMPAT_NUM    = 0;
  localparam RB_NUM_HB        = 1;
  localparam RB_CIC_MAX_DECIM = 2;
  localparam COMPAT_NUM       = {COMPAT_NUM_MAJOR, COMPAT_NUM_MINOR};
  localparam MAX_N = CIC_MAX_DECIM * 2<<(NUM_HB-1);

  localparam SR_ENABLE_OUTPUT = 150;

  ////////////////////////////////////////////////////////////
  //
  // FIRST AXI Wrapper
  // Convert RFNoC Shell interface into AXI stream interface
  // (first channel data gets split into all other data)
  //
  ////////////////////////////////////////////////////////////

  wire [31:0]  m_axis_ch0_tdata;
  wire         m_axis_ch0_tlast;
  wire         m_axis_ch0_tvalid;
  wire         m_axis_ch0_tready;
  wire [127:0] m_axis_ch0_tuser;

  wire [31:0]  s_axis_ch0_tdata;
  wire         s_axis_ch0_tlast;
  wire         s_axis_ch0_tvalid;
  wire         s_axis_ch0_tready;
  wire [127:0] s_axis_ch0_tuser;

  wire clear_user_ch0;

  wire        set_stb_ch0      = set_stb[0];
  wire [7:0]  set_addr_ch0     = set_addr[7:0];
  wire [31:0] set_data_ch0     = set_data[31:0];
  wire [63:0] set_time_ch0     = set_time[63:0];
  wire        set_has_time_ch0 = set_has_time[0];

  // TODO Readback register for number of FIR filter taps
  always @*
    case(rb_addr[7:0])
      RB_COMPAT_NUM    : rb_data[63:0] <= {COMPAT_NUM};
      RB_NUM_HB        : rb_data[63:0] <= {NUM_HB};
      RB_CIC_MAX_DECIM : rb_data[63:0] <= {CIC_MAX_DECIM};
      default          : rb_data[63:0] <= 64'h0BADC0DE0BADC0DE;
    endcase

  axi_wrapper #(
    .SIMPLE_MODE(0), .MTU(MTU))
  axi_wrapper_ch0 (
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .clk(ce_clk), .reset(ce_rst),
    .clear_tx_seqnum(clear_tx_seqnum[0]),
    .next_dst(next_dst_sid[15:0]),
    .set_stb(set_stb_ch0), .set_addr(set_addr_ch0), .set_data(set_data_ch0),
    .i_tdata(str_sink_tdata[63:0]), .i_tlast(str_sink_tlast[0]), .i_tvalid(str_sink_tvalid[0]), .i_tready(str_sink_tready[0]),
    .o_tdata(str_src_tdata[63:0]), .o_tlast(str_src_tlast[0]), .o_tvalid(str_src_tvalid[0]), .o_tready(str_src_tready[0]),
    .m_axis_data_tdata(m_axis_ch0_tdata),
    .m_axis_data_tlast(m_axis_ch0_tlast),
    .m_axis_data_tvalid(m_axis_ch0_tvalid),
    .m_axis_data_tready(m_axis_ch0_tready),
    .m_axis_data_tuser(m_axis_ch0_tuser),
    .s_axis_data_tdata(s_axis_ch0_tdata),
    .s_axis_data_tlast(s_axis_ch0_tlast),
    .s_axis_data_tvalid(s_axis_ch0_tvalid),
    .s_axis_data_tready(s_axis_ch0_tready),
    .s_axis_data_tuser(s_axis_ch0_tuser),
    .m_axis_config_tdata(),
    .m_axis_config_tlast(),
    .m_axis_config_tvalid(),
    .m_axis_config_tready(),
    .m_axis_pkt_len_tdata(),
    .m_axis_pkt_len_tvalid(),
    .m_axis_pkt_len_tready());

  wire [NUM_CHAINS*32-1:0]  m_axis_split_tdata;
  wire [NUM_CHAINS-1:0]     m_axis_split_tlast;
  wire [NUM_CHAINS-1:0]     m_axis_split_tvalid;
  wire [NUM_CHAINS-1:0]     m_axis_split_tready;
  wire [NUM_CHAINS*128-1:0] m_axis_split_tuser;

  multi_split_stream #(
    .WIDTH(32),
    .USER_WIDTH(128),
    .OUTPUTS(NUM_CHAINS))
  input_splitter (
    .clk(ce_clk), .reset(ce_rst), .clear(clear_tx_seqnum[0]),
    .i_tdata(m_axis_ch0_tdata),
    .i_tlast(m_axis_ch0_tlast),
    .i_tvalid(m_axis_ch0_tvalid),
    .i_tready(m_axis_ch0_tready),
    .i_tuser(m_axis_ch0_tuser),
    .o_tdata(m_axis_split_tdata),
    .o_tlast(m_axis_split_tlast),
    .o_tvalid(m_axis_split_tvalid),
    .o_tready(m_axis_split_tready),
    .o_tuser(m_axis_split_tuser));

  // split_stream_fifo #(.WIDTH(128+32), .ACTIVE_MASK(4'b0011)) tuser_splitter (
  //   .clk(ce_clk), .reset(ce_rst), .clear(clear_tx_seqnum[0]),
  //   .i_tdata({m_axis_ch0_tuser, m_axis_ch0_tdata}),
  //   .i_tlast(m_axis_ch0_tlast),
  //   .i_tvalid(m_axis_ch0_tvalid),
  //   .i_tready(m_axis_ch0_tready),
  //   .o0_tdata({m_axis_split_tuser[127:0], m_axis_split_tdata[31:0]}),
  //   .o0_tlast(m_axis_split_tlast[0]),
  //   .o0_tvalid(m_axis_split_tvalid[0]),
  //   .o0_tready(m_axis_split_tready[0]),
  //   .o1_tdata({m_axis_split_tuser[255:128], m_axis_split_tdata[63:32]}),
  //   .o1_tlast(m_axis_split_tlast[1]),
  //   .o1_tvalid(m_axis_split_tvalid[1]),
  //   .o1_tready(m_axis_split_tready[1]),
  //   .o2_tready(1'b1), .o3_tready(1'b1));

  // TODO: Figure out if we need FIFOs for each individual split stream

  ////////////////////////////////////////////////////////////
  //
  // Timed Commands
  //
  ////////////////////////////////////////////////////////////
  wire [31:0]  m_axis_tagch0_tdata;
  wire         m_axis_tagch0_tlast;
  wire         m_axis_tagch0_tvalid;
  wire         m_axis_tagch0_tready;
  wire [127:0] m_axis_tagch0_tuser;
  wire         m_axis_tagch0_tag;

  wire         out_ch0_stb;
  wire [7:0]   out_ch0_addr;
  wire [31:0]  out_ch0_data;
  wire         timed_ch0_stb;
  wire [7:0]   timed_ch0_addr;
  wire [31:0]  timed_ch0_data;

  wire         timed_cmd_fifo_full;

  axi_tag_time #(
    .NUM_TAGS(1),
    .SR_TAG_ADDRS(SR_FREQ_ADDR))
  axi_tag_time_ch0 (
    .clk(ce_clk),
    .reset(ce_rst),
    .clear(clear_tx_seqnum[0]),
    .tick_rate(16'd1),
    .timed_cmd_fifo_full(timed_cmd_fifo_full),
    .s_axis_data_tdata(m_axis_split_tdata[31:0]), .s_axis_data_tlast(m_axis_split_tlast[0]),
    .s_axis_data_tvalid(m_axis_split_tvalid[0]), .s_axis_data_tready(m_axis_split_tready[0]),
    .s_axis_data_tuser(m_axis_split_tuser[127:0]),
    .m_axis_data_tdata(m_axis_tagch0_tdata), .m_axis_data_tlast(m_axis_tagch0_tlast),
    .m_axis_data_tvalid(m_axis_tagch0_tvalid), .m_axis_data_tready(m_axis_tagch0_tready),
    .m_axis_data_tuser(m_axis_tagch0_tuser), .m_axis_data_tag(m_axis_tagch0_tag),
    .in_set_stb(set_stb_ch0), .in_set_addr(set_addr_ch0), .in_set_data(set_data_ch0),
    .in_set_time(set_time_ch0), .in_set_has_time(set_has_time_ch0),
    .out_set_stb(out_ch0_stb), .out_set_addr(out_ch0_addr), .out_set_data(out_ch0_data),
    .timed_set_stb(timed_ch0_stb), .timed_set_addr(timed_ch0_addr), .timed_set_data(timed_ch0_data));

  // Hold off reading additional commands if internal FIFO is full
  assign rb_stb[0] = ~timed_cmd_fifo_full;

  ////////////////////////////////////////////////////////////
  //
  // Reduce Rate
  //
  ////////////////////////////////////////////////////////////
  wire [31:0] ddc_ch0_in_tdata, ddc_ch0_out_tdata;
  wire ddc_ch0_in_tuser, ddc_ch0_in_eob;
  wire ddc_ch0_in_tvalid, ddc_ch0_in_tready, ddc_ch0_in_tlast;
  wire ddc_ch0_out_tvalid, ddc_ch0_out_tready;
  wire nc;
  wire warning_long_throttle;
  wire error_extra_outputs;
  wire error_drop_pkt_lockup;
  axi_rate_change #(
    .WIDTH(33),
    .MAX_N(MAX_N),
    .MAX_M(1),
    .SR_N_ADDR(SR_N_ADDR),
    .SR_M_ADDR(SR_M_ADDR),
    .SR_CONFIG_ADDR(SR_CONFIG_ADDR))
  axi_rate_change_ch0 (
    .clk(ce_clk), .reset(ce_rst), .clear(clear_tx_seqnum[0]), .clear_user(clear_user_ch0),
    .src_sid(src_sid[15:0]), .dst_sid(next_dst_sid[15:0]),
    .set_stb(out_ch0_stb), .set_addr(out_ch0_addr), .set_data(out_ch0_data),
    .i_tdata({m_axis_tagch0_tag,m_axis_tagch0_tdata}), .i_tlast(m_axis_tagch0_tlast),
    .i_tvalid(m_axis_tagch0_tvalid), .i_tready(m_axis_tagch0_tready),
    .i_tuser(m_axis_tagch0_tuser),
    .o_tdata({nc,s_axis_ch0_tdata}), .o_tlast(s_axis_ch0_tlast), .o_tvalid(s_axis_ch0_tvalid),
    .o_tready(s_axis_ch0_tready), .o_tuser(s_axis_ch0_tuser),
    .m_axis_data_tdata({ddc_ch0_in_tuser,ddc_ch0_in_tdata}), .m_axis_data_tlast(ddc_ch0_in_tlast),
    .m_axis_data_tvalid(ddc_ch0_in_tvalid), .m_axis_data_tready(ddc_ch0_in_tready),
    .s_axis_data_tdata({1'b0,ddc_ch0_out_tdata}), .s_axis_data_tlast(1'b0),
    .s_axis_data_tvalid(ddc_ch0_out_tvalid), .s_axis_data_tready(ddc_ch0_out_tready),
    .warning_long_throttle(warning_long_throttle),
    .error_extra_outputs(error_extra_outputs),
    .error_drop_pkt_lockup(error_drop_pkt_lockup));

  assign ddc_ch0_in_eob = m_axis_tagch0_tuser[124]; //this should align with last packet output from axi_rate_change

  ////////////////////////////////////////////////////////////
  //
  // Digital Down Converter
  //
  ////////////////////////////////////////////////////////////

  ddc #(
    .SR_FREQ_ADDR(SR_FREQ_ADDR),
    .SR_SCALE_IQ_ADDR(SR_SCALE_IQ_ADDR),
    .SR_DECIM_ADDR(SR_DECIM_ADDR),
    .SR_MUX_ADDR(SR_MUX_ADDR),
    .SR_COEFFS_ADDR(SR_COEFFS_ADDR),
    .NUM_HB(NUM_HB),
    .CIC_MAX_DECIM(CIC_MAX_DECIM))
  ddc_ch0 (
    .clk(ce_clk), .reset(ce_rst),
    .clear(clear_user_ch0 | clear_tx_seqnum[0]), // Use AXI Rate Change's clear user to reset block to initial state after EOB
    .set_stb(out_ch0_stb), .set_addr(out_ch0_addr), .set_data(out_ch0_data),
    .timed_set_stb(timed_ch0_stb), .timed_set_addr(timed_ch0_addr), .timed_set_data(timed_ch0_data),
    .sample_in_tdata(ddc_ch0_in_tdata), .sample_in_tlast(ddc_ch0_in_tlast),
    .sample_in_tvalid(ddc_ch0_in_tvalid), .sample_in_tready(ddc_ch0_in_tready),
    .sample_in_tuser(ddc_ch0_in_tuser), .sample_in_eob(ddc_ch0_in_eob),
    .sample_out_tdata(ddc_ch0_out_tdata), .sample_out_tlast(),
    .sample_out_tvalid(ddc_ch0_out_tvalid), .sample_out_tready(ddc_ch0_out_tready));

  genvar i;
  generate
    for (i = 1; i < NUM_CHAINS; i = i + 1) begin : gen_ddc_chains
      ////////////////////////////////////////////////////////////
      //
      // Remaining AXI Wrapper(s)
      // Convert RFNoC Shell interface into AXI stream interface
      // (first channel data gets split into all other data)
      //
      ////////////////////////////////////////////////////////////

      wire [31:0]  m_axis_data_tdata = m_axis_split_tdata[32*i+31:32*i];
      wire         m_axis_data_tlast = m_axis_split_tlast[i];
      wire         m_axis_data_tvalid = m_axis_split_tvalid[i];
      wire         m_axis_data_tready;
      wire [127:0] m_axis_data_tuser = m_axis_split_tuser[128*i+127:128*i];
      assign  m_axis_split_tready[i] = m_axis_data_tready;

      wire [31:0]  s_axis_data_tdata;
      wire         s_axis_data_tlast;
      wire         s_axis_data_tvalid;
      wire         s_axis_data_tready;
      wire [127:0] s_axis_data_tuser;

      wire clear_user;

      wire        set_stb_int      = set_stb[i];
      wire [7:0]  set_addr_int     = set_addr[8*i+7:8*i];
      wire [31:0] set_data_int     = set_data[32*i+31:32*i];
      wire [63:0] set_time_int     = set_time[64*i+63:64*i];
      wire        set_has_time_int = set_has_time[i];

      // When this channel is DISABLED:
      //  - master tvalid into ddc goes LOW (dont process data)
      //  - slave tvalid out of ddc goes LOW (dont write data to axi_wrapper)
      //  - slave tready out of ddc held HIGH (flush any remaining data)
      wire enable_channel;
      wire input_tvalid = m_axis_data_tvalid & enable_channel;
      wire output_tvalid = s_axis_data_tvalid & enable_channel;
      wire output_tready = s_axis_data_tready | ~enable_channel;

      // TODO Readback register for number of FIR filter taps
      always @*
        case(rb_addr[8*i+7:8*i])
          RB_COMPAT_NUM    : rb_data[64*i+63:64*i] <= {COMPAT_NUM};
          RB_NUM_HB        : rb_data[64*i+63:64*i] <= {NUM_HB};
          RB_CIC_MAX_DECIM : rb_data[64*i+63:64*i] <= {CIC_MAX_DECIM};
          default          : rb_data[64*i+63:64*i] <= 64'h0BADC0DE0BADC0DE;
        endcase

      axi_wrapper #(
        .SIMPLE_MODE(0), .MTU(MTU))
      axi_wrapper (
        .bus_clk(bus_clk), .bus_rst(bus_rst),
        .clk(ce_clk), .reset(ce_rst),
        .clear_tx_seqnum(clear_tx_seqnum[i]),
        .next_dst(next_dst_sid[16*i+15:16*i]),
        .set_stb(set_stb_int), .set_addr(set_addr_int), .set_data(set_data_int),
        .i_tdata(str_sink_tdata[64*i+63:64*i]), .i_tlast(str_sink_tlast[i]), .i_tvalid(str_sink_tvalid[i]), .i_tready(str_sink_tready[i]),
        .o_tdata(str_src_tdata[64*i+63:64*i]), .o_tlast(str_src_tlast[i]), .o_tvalid(str_src_tvalid[i]), .o_tready(str_src_tready[i]),
        .m_axis_data_tdata(),
        .m_axis_data_tlast(),
        .m_axis_data_tvalid(),
        .m_axis_data_tready(1'b1),
        .m_axis_data_tuser(),
        .s_axis_data_tdata(s_axis_data_tdata),
        .s_axis_data_tlast(s_axis_data_tlast),
        .s_axis_data_tvalid(output_tvalid),
        .s_axis_data_tready(s_axis_data_tready),
        .s_axis_data_tuser(s_axis_data_tuser),
        .m_axis_config_tdata(),
        .m_axis_config_tlast(),
        .m_axis_config_tvalid(),
        .m_axis_config_tready(),
        .m_axis_pkt_len_tdata(),
        .m_axis_pkt_len_tvalid(),
        .m_axis_pkt_len_tready());

      setting_reg #(.my_addr(SR_ENABLE_OUTPUT), .at_reset(0), .width(1))
      sr_enable_channel (
        .clk(ce_clk), .rst(ce_rst), .strobe(set_stb_int), .addr(set_addr_int),
        .in(set_data_int), .out(enable_channel), .changed());

      ////////////////////////////////////////////////////////////
      //
      // Timed Commands
      //
      ////////////////////////////////////////////////////////////
      wire [31:0]  m_axis_tagged_tdata;
      wire         m_axis_tagged_tlast;
      wire         m_axis_tagged_tvalid;
      wire         m_axis_tagged_tready;
      wire [127:0] m_axis_tagged_tuser;
      wire         m_axis_tagged_tag;

      wire         out_set_stb;
      wire [7:0]   out_set_addr;
      wire [31:0]  out_set_data;
      wire         timed_set_stb;
      wire [7:0]   timed_set_addr;
      wire [31:0]  timed_set_data;

      wire         timed_cmd_fifo_full;

      axi_tag_time #(
        .NUM_TAGS(1),
        .SR_TAG_ADDRS(SR_FREQ_ADDR))
      axi_tag_time (
        .clk(ce_clk),
        .reset(ce_rst),
        .clear(clear_tx_seqnum[i]),
        .tick_rate(16'd1),
        .timed_cmd_fifo_full(timed_cmd_fifo_full),
        .s_axis_data_tdata(m_axis_data_tdata), .s_axis_data_tlast(m_axis_data_tlast),
        .s_axis_data_tvalid(input_tvalid), .s_axis_data_tready(m_axis_data_tready),
        .s_axis_data_tuser(m_axis_data_tuser),
        .m_axis_data_tdata(m_axis_tagged_tdata), .m_axis_data_tlast(m_axis_tagged_tlast),
        .m_axis_data_tvalid(m_axis_tagged_tvalid), .m_axis_data_tready(m_axis_tagged_tready),
        .m_axis_data_tuser(m_axis_tagged_tuser), .m_axis_data_tag(m_axis_tagged_tag),
        .in_set_stb(set_stb_int), .in_set_addr(set_addr_int), .in_set_data(set_data_int),
        .in_set_time(set_time_int), .in_set_has_time(set_has_time_int),
        .out_set_stb(out_set_stb), .out_set_addr(out_set_addr), .out_set_data(out_set_data),
        .timed_set_stb(timed_set_stb), .timed_set_addr(timed_set_addr), .timed_set_data(timed_set_data));

      // Hold off reading additional commands if internal FIFO is full
      assign rb_stb[i] = ~timed_cmd_fifo_full;

      ////////////////////////////////////////////////////////////
      //
      // Reduce Rate
      //
      ////////////////////////////////////////////////////////////
      wire [31:0] sample_in_tdata, sample_out_tdata;
      wire sample_in_tuser, sample_in_eob;
      wire sample_in_tvalid, sample_in_tready, sample_in_tlast;
      wire sample_out_tvalid, sample_out_tready;
      wire nc;
      wire warning_long_throttle;
      wire error_extra_outputs;
      wire error_drop_pkt_lockup;
      axi_rate_change #(
        .WIDTH(33),
        .MAX_N(MAX_N),
        .MAX_M(1),
        .SR_N_ADDR(SR_N_ADDR),
        .SR_M_ADDR(SR_M_ADDR),
        .SR_CONFIG_ADDR(SR_CONFIG_ADDR))
      axi_rate_change (
        .clk(ce_clk), .reset(ce_rst), .clear(clear_tx_seqnum[i]), .clear_user(clear_user),
        .src_sid(src_sid[16*i+15:16*i]), .dst_sid(next_dst_sid[16*i+15:16*i]),
        .set_stb(out_set_stb), .set_addr(out_set_addr), .set_data(out_set_data),
        .i_tdata({m_axis_tagged_tag,m_axis_tagged_tdata}), .i_tlast(m_axis_tagged_tlast),
        .i_tvalid(m_axis_tagged_tvalid), .i_tready(m_axis_tagged_tready),
        .i_tuser(m_axis_tagged_tuser),
        .o_tdata({nc,s_axis_data_tdata}), .o_tlast(s_axis_data_tlast), .o_tvalid(s_axis_data_tvalid),
        .o_tready(output_tready), .o_tuser(s_axis_data_tuser),
        .m_axis_data_tdata({sample_in_tuser,sample_in_tdata}), .m_axis_data_tlast(sample_in_tlast),
        .m_axis_data_tvalid(sample_in_tvalid), .m_axis_data_tready(sample_in_tready),
        .s_axis_data_tdata({1'b0,sample_out_tdata}), .s_axis_data_tlast(1'b0),
        .s_axis_data_tvalid(sample_out_tvalid), .s_axis_data_tready(sample_out_tready),
        .warning_long_throttle(warning_long_throttle),
        .error_extra_outputs(error_extra_outputs),
        .error_drop_pkt_lockup(error_drop_pkt_lockup));

      assign sample_in_eob = m_axis_tagged_tuser[124]; //this should align with last packet output from axi_rate_change

      ////////////////////////////////////////////////////////////
      //
      // Digital Down Converter
      //
      ////////////////////////////////////////////////////////////

      ddc #(
        .SR_FREQ_ADDR(SR_FREQ_ADDR),
        .SR_SCALE_IQ_ADDR(SR_SCALE_IQ_ADDR),
        .SR_DECIM_ADDR(SR_DECIM_ADDR),
        .SR_MUX_ADDR(SR_MUX_ADDR),
        .SR_COEFFS_ADDR(SR_COEFFS_ADDR),
        .NUM_HB(NUM_HB),
        .CIC_MAX_DECIM(CIC_MAX_DECIM))
      ddc (
        .clk(ce_clk), .reset(ce_rst),
        .clear(clear_user | clear_tx_seqnum[i]), // Use AXI Rate Change's clear user to reset block to initial state after EOB
        .set_stb(out_set_stb), .set_addr(out_set_addr), .set_data(out_set_data),
        .timed_set_stb(timed_set_stb), .timed_set_addr(timed_set_addr), .timed_set_data(timed_set_data),
        .sample_in_tdata(sample_in_tdata), .sample_in_tlast(sample_in_tlast),
        .sample_in_tvalid(sample_in_tvalid), .sample_in_tready(sample_in_tready),
        .sample_in_tuser(sample_in_tuser), .sample_in_eob(sample_in_eob),
        .sample_out_tdata(sample_out_tdata), .sample_out_tlast(),
        .sample_out_tvalid(sample_out_tvalid), .sample_out_tready(sample_out_tready)
        );

    end
  endgenerate

endmodule
