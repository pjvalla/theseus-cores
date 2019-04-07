/*****************************************************************************/
// Implements the M/2 PFB architecture referenced in the
// "A Versatile Multichannel Filter Bank with Multiple Channel Bandwidths" paper.
// This architecture has been mapped to the Xilinx architecture.
// This represents a fully pipelined design that maximizes the FMax potential of the design. It is important
// to understand that filter arms are loaded sequentially. This is referenced in the diagram by the
// incremental changes in the phase subscript through each subsequent delay register.
// The nth index is only updated once per revolution of the filter bank.
//
// It is best to refer to the attached document to understand the layout of the logic. This module
// currently implements 32 taps per phase.
/*****************************************************************************/

module pfb_2x_16iw_16ow_32tps
(
    input clk,
    input sync_reset,

    input [11:0] fft_size,
    input [10:0] phase,
    input s_axis_tvalid,
    input [31:0] s_axis_tdata,
    input s_axis_tlast,
    output s_axis_tready,

    input [31:0] s_axis_reload_tdata,
    input s_axis_reload_tlast,
    input s_axis_reload_tvalid,
    output s_axis_reload_tready,

    output [10:0] phase_out,
    output m_axis_tvalid,
    output [31:0] m_axis_tdata,
    output m_axis_tlast,
    input m_axis_tready
);

wire [24:0] taps[0:31];
wire [47:0] pcouti[0:31];
wire [47:0] pcoutq[0:31];
wire [15:0] pouti, poutq;

wire [31:0] delay[0:31];
wire [31:0] delay_sig;

reg [10:0] phase_d[0:38];
reg [10:0] phase_mux_d[0:2];
reg [7:0] tvalid_d;
reg [42:0] tvalid_pipe, next_tvalid_pipe;
reg [42:0] tlast_d, next_tlast_d;

reg [12:0] wr_addr_d[0:95];

reg [12:0] rd_addr, next_rd_addr;
reg [12:0] wr_addr, next_wr_addr;
reg [12:0] rd_addr_d[0:30];

reg [12:0] next_rd_addr_d[0:30];

reg [31:0] input_sig_d1, input_sig_d2, input_sig_d3;
reg [31:0] sig, next_sig;
reg [31:0] sig_d1, sig_d2, sig_d3;
reg [1:0] offset_cnt, next_offset_cnt;
reg [1:0] offset_cnt_prev, next_offset_cnt_prev;

reg s_axis_reload_tvalid_d1;
reg [15:0] taps_addr, next_taps_addr;

reg [24:0] taps_dina, next_taps_dina;
reg [10:0] rom_addr, next_rom_addr;
reg [24:0] rom_data, next_rom_data;
reg reload_tready = 1'b0;

reg new_coeffs, next_new_coeffs;
reg [31:0] taps_we, next_taps_we;

reg [11:0] fft_max;
reg [10:0] fft_max_slice;
reg [11:0] fft_half;
wire [42:0] fifo_tdata, m_axis_tdata_s;
wire fifo_tvalid;
wire almost_full;
wire tap_take;
reg tap_take_d1;
wire bot_half;

assign m_axis_tdata = m_axis_tdata_s[42:11];
assign s_axis_tready = ~almost_full;
assign fifo_tvalid = tvalid_d[7] & tvalid_pipe[42];
assign tap_take = s_axis_reload_tvalid & reload_tready;
assign phase_out = m_axis_tdata_s[10:0];
assign fifo_tdata = {pouti, poutq, phase_d[38]};
assign s_axis_reload_tready = reload_tready;

assign bot_half = ((phase_mux_d[2] & fft_half[10:0]) != 0) ? 1'b1 : 1'b0;

// logic implements the sample write address pipelining.
always @(posedge clk)
begin

    fft_max <= fft_size - 1;
    fft_max_slice <= fft_max[10:0];
    fft_half <= fft_size >> 1;

    phase_mux_d[0] <= phase;
    phase_mux_d[1] <= phase_mux_d[0] & fft_max_slice;
    phase_mux_d[2] <= phase_mux_d[1];
    phase_d[0] <= rd_addr[10:0];
    phase_d[1] <= phase_d[0];
    phase_d[2] <= phase_d[1];
    s_axis_reload_tvalid_d1 <= s_axis_reload_tvalid;

    input_sig_d1 <= s_axis_tdata;
    input_sig_d2 <= input_sig_d1;
    input_sig_d3 <= input_sig_d2;

    wr_addr_d[0] <= wr_addr;
    wr_addr_d[3] <= {~rd_addr[12], rd_addr[11], rd_addr[10:0]};
    wr_addr_d[6] <= {~rd_addr_d[0][12], rd_addr_d[0][11], rd_addr_d[0][10:0]};
    wr_addr_d[9] <= {~rd_addr_d[1][12], rd_addr_d[1][11], rd_addr_d[1][10:0]};
    wr_addr_d[12] <= {~rd_addr_d[2][12], rd_addr_d[2][11], rd_addr_d[2][10:0]};
    wr_addr_d[15] <= {~rd_addr_d[3][12], rd_addr_d[3][11], rd_addr_d[3][10:0]};
    wr_addr_d[18] <= {~rd_addr_d[4][12], rd_addr_d[4][11], rd_addr_d[4][10:0]};
    wr_addr_d[21] <= {~rd_addr_d[5][12], rd_addr_d[5][11], rd_addr_d[5][10:0]};
    wr_addr_d[24] <= {~rd_addr_d[6][12], rd_addr_d[6][11], rd_addr_d[6][10:0]};
    wr_addr_d[27] <= {~rd_addr_d[7][12], rd_addr_d[7][11], rd_addr_d[7][10:0]};
    wr_addr_d[30] <= {~rd_addr_d[8][12], rd_addr_d[8][11], rd_addr_d[8][10:0]};
    wr_addr_d[33] <= {~rd_addr_d[9][12], rd_addr_d[9][11], rd_addr_d[9][10:0]};
    wr_addr_d[36] <= {~rd_addr_d[10][12], rd_addr_d[10][11], rd_addr_d[10][10:0]};
    wr_addr_d[39] <= {~rd_addr_d[11][12], rd_addr_d[11][11], rd_addr_d[11][10:0]};
    wr_addr_d[42] <= {~rd_addr_d[12][12], rd_addr_d[12][11], rd_addr_d[12][10:0]};
    wr_addr_d[45] <= {~rd_addr_d[13][12], rd_addr_d[13][11], rd_addr_d[13][10:0]};
    wr_addr_d[48] <= {~rd_addr_d[14][12], rd_addr_d[14][11], rd_addr_d[14][10:0]};
    wr_addr_d[51] <= {~rd_addr_d[15][12], rd_addr_d[15][11], rd_addr_d[15][10:0]};
    wr_addr_d[54] <= {~rd_addr_d[16][12], rd_addr_d[16][11], rd_addr_d[16][10:0]};
    wr_addr_d[57] <= {~rd_addr_d[17][12], rd_addr_d[17][11], rd_addr_d[17][10:0]};
    wr_addr_d[60] <= {~rd_addr_d[18][12], rd_addr_d[18][11], rd_addr_d[18][10:0]};
    wr_addr_d[63] <= {~rd_addr_d[19][12], rd_addr_d[19][11], rd_addr_d[19][10:0]};
    wr_addr_d[66] <= {~rd_addr_d[20][12], rd_addr_d[20][11], rd_addr_d[20][10:0]};
    wr_addr_d[69] <= {~rd_addr_d[21][12], rd_addr_d[21][11], rd_addr_d[21][10:0]};
    wr_addr_d[72] <= {~rd_addr_d[22][12], rd_addr_d[22][11], rd_addr_d[22][10:0]};
    wr_addr_d[75] <= {~rd_addr_d[23][12], rd_addr_d[23][11], rd_addr_d[23][10:0]};
    wr_addr_d[78] <= {~rd_addr_d[24][12], rd_addr_d[24][11], rd_addr_d[24][10:0]};
    wr_addr_d[81] <= {~rd_addr_d[25][12], rd_addr_d[25][11], rd_addr_d[25][10:0]};
    wr_addr_d[84] <= {~rd_addr_d[26][12], rd_addr_d[26][11], rd_addr_d[26][10:0]};
    wr_addr_d[87] <= {~rd_addr_d[27][12], rd_addr_d[27][11], rd_addr_d[27][10:0]};
    wr_addr_d[90] <= {~rd_addr_d[28][12], rd_addr_d[28][11], rd_addr_d[28][10:0]};
    wr_addr_d[93] <= {~rd_addr_d[29][12], rd_addr_d[29][11], rd_addr_d[29][10:0]};

    wr_addr_d[1] <= wr_addr_d[0];
    wr_addr_d[2] <= wr_addr_d[1];
    wr_addr_d[4] <= wr_addr_d[3];
    wr_addr_d[5] <= wr_addr_d[4];
    wr_addr_d[7] <= wr_addr_d[6];
    wr_addr_d[8] <= wr_addr_d[7];
    wr_addr_d[10] <= wr_addr_d[9];
    wr_addr_d[11] <= wr_addr_d[10];
    wr_addr_d[13] <= wr_addr_d[12];
    wr_addr_d[14] <= wr_addr_d[13];
    wr_addr_d[16] <= wr_addr_d[15];
    wr_addr_d[17] <= wr_addr_d[16];
    wr_addr_d[19] <= wr_addr_d[18];
    wr_addr_d[20] <= wr_addr_d[19];
    wr_addr_d[22] <= wr_addr_d[21];
    wr_addr_d[23] <= wr_addr_d[22];
    wr_addr_d[25] <= wr_addr_d[24];
    wr_addr_d[26] <= wr_addr_d[25];
    wr_addr_d[28] <= wr_addr_d[27];
    wr_addr_d[29] <= wr_addr_d[28];
    wr_addr_d[31] <= wr_addr_d[30];
    wr_addr_d[32] <= wr_addr_d[31];
    wr_addr_d[34] <= wr_addr_d[33];
    wr_addr_d[35] <= wr_addr_d[34];
    wr_addr_d[37] <= wr_addr_d[36];
    wr_addr_d[38] <= wr_addr_d[37];
    wr_addr_d[40] <= wr_addr_d[39];
    wr_addr_d[41] <= wr_addr_d[40];
    wr_addr_d[43] <= wr_addr_d[42];
    wr_addr_d[44] <= wr_addr_d[43];
    wr_addr_d[46] <= wr_addr_d[45];
    wr_addr_d[47] <= wr_addr_d[46];
    wr_addr_d[49] <= wr_addr_d[48];
    wr_addr_d[50] <= wr_addr_d[49];
    wr_addr_d[52] <= wr_addr_d[51];
    wr_addr_d[53] <= wr_addr_d[52];
    wr_addr_d[55] <= wr_addr_d[54];
    wr_addr_d[56] <= wr_addr_d[55];
    wr_addr_d[58] <= wr_addr_d[57];
    wr_addr_d[59] <= wr_addr_d[58];
    wr_addr_d[61] <= wr_addr_d[60];
    wr_addr_d[62] <= wr_addr_d[61];
    wr_addr_d[64] <= wr_addr_d[63];
    wr_addr_d[65] <= wr_addr_d[64];
    wr_addr_d[67] <= wr_addr_d[66];
    wr_addr_d[68] <= wr_addr_d[67];
    wr_addr_d[70] <= wr_addr_d[69];
    wr_addr_d[71] <= wr_addr_d[70];
    wr_addr_d[73] <= wr_addr_d[72];
    wr_addr_d[74] <= wr_addr_d[73];
    wr_addr_d[76] <= wr_addr_d[75];
    wr_addr_d[77] <= wr_addr_d[76];
    wr_addr_d[79] <= wr_addr_d[78];
    wr_addr_d[80] <= wr_addr_d[79];
    wr_addr_d[82] <= wr_addr_d[81];
    wr_addr_d[83] <= wr_addr_d[82];
    wr_addr_d[85] <= wr_addr_d[84];
    wr_addr_d[86] <= wr_addr_d[85];
    wr_addr_d[88] <= wr_addr_d[87];
    wr_addr_d[89] <= wr_addr_d[88];
    wr_addr_d[91] <= wr_addr_d[90];
    wr_addr_d[92] <= wr_addr_d[91];
    wr_addr_d[94] <= wr_addr_d[93];
    wr_addr_d[95] <= wr_addr_d[94];
    sig_d1 <= sig;
    sig_d2 <= sig_d1;
    sig_d3 <= sig_d2;
    tap_take_d1 <= tap_take;
end

//tvalid_pipe_proc
always @*
begin
    next_tvalid_pipe[6:0] = {tvalid_pipe[5:0], (s_axis_tvalid & ~almost_full)};
    if (tvalid_d[6] == 1'b1) begin
        next_tvalid_pipe[42:7] = {tvalid_pipe[41:7],tvalid_pipe[6]};
    end else begin
        next_tvalid_pipe[42:7] = tvalid_pipe[42:7];
    end
end

//tlast_proc 
always @*
begin
    next_tlast_d[6:0] = {tlast_d[5:0], s_axis_tlast};
    if (tvalid_d[6] == 1'b1) begin
        next_tlast_d[42:7] = {tlast_d[41:7], tlast_d[6]};
    end else begin
        next_tlast_d[42:7] = tlast_d[42:7];
    end
end

// clock and reset process.
integer m;
always @(posedge clk, posedge sync_reset)
begin
	if (sync_reset == 1'b1) begin
          offset_cnt <= 1;  // this ensures that the first read / write is to offset 0.
          offset_cnt_prev <= 0;
          sig <= 0;
          tvalid_d <= 0;
          tvalid_pipe <= 0;
          tlast_d <= 0;
          for (m=0; m<31; m=m+1) begin
              rd_addr_d[m] <= 0;
          end
          new_coeffs <= 1'b1;
          taps_addr <= 0;
          rom_addr <= 0;
          rom_data <= 0;
          taps_we <= 0;
          taps_dina <= 0;
          rd_addr <= 0;
          wr_addr <= 0;
          reload_tready <= 1'b0;
	end else begin
          offset_cnt <= next_offset_cnt;
          offset_cnt_prev <= next_offset_cnt_prev;
          sig <= next_sig;
          tvalid_d <= {tvalid_d[6:0], (s_axis_tvalid & ~almost_full)};
          tvalid_pipe <= next_tvalid_pipe;
          tlast_d <= next_tlast_d;
          for (m=0; m<31; m=m+1) begin
              rd_addr_d[m] <= next_rd_addr_d[m];
          end
          new_coeffs <= next_new_coeffs;
          taps_addr <= next_taps_addr;
          rom_addr <= next_rom_addr;
          rom_data <= next_rom_data;
          taps_we <= next_taps_we;
          taps_dina <= next_taps_dina;
          rd_addr <= next_rd_addr;
          wr_addr <= next_wr_addr;
          reload_tready <= 1'b1;
	end
end

always @(posedge clk)
begin
    if (tvalid_d[6] == 1'b1) begin
        phase_d[3] <= phase_d[2];
        phase_d[4] <= phase_d[3];
        phase_d[5] <= phase_d[4];
        phase_d[6] <= phase_d[5];
        phase_d[7] <= phase_d[6];
        phase_d[8] <= phase_d[7];
        phase_d[9] <= phase_d[8];
        phase_d[10] <= phase_d[9];
        phase_d[11] <= phase_d[10];
        phase_d[12] <= phase_d[11];
        phase_d[13] <= phase_d[12];
        phase_d[14] <= phase_d[13];
        phase_d[15] <= phase_d[14];
        phase_d[16] <= phase_d[15];
        phase_d[17] <= phase_d[16];
        phase_d[18] <= phase_d[17];
        phase_d[19] <= phase_d[18];
        phase_d[20] <= phase_d[19];
        phase_d[21] <= phase_d[20];
        phase_d[22] <= phase_d[21];
        phase_d[23] <= phase_d[22];
        phase_d[24] <= phase_d[23];
        phase_d[25] <= phase_d[24];
        phase_d[26] <= phase_d[25];
        phase_d[27] <= phase_d[26];
        phase_d[28] <= phase_d[27];
        phase_d[29] <= phase_d[28];
        phase_d[30] <= phase_d[29];
        phase_d[31] <= phase_d[30];
        phase_d[32] <= phase_d[31];
        phase_d[33] <= phase_d[32];
        phase_d[34] <= phase_d[33];
        phase_d[35] <= phase_d[34];
        phase_d[36] <= phase_d[35];
        phase_d[37] <= phase_d[36];
        phase_d[38] <= phase_d[37];
    end
end

// reload process
integer n;
always @*
begin
    next_taps_addr = taps_addr;
    next_taps_dina = taps_dina;
    next_new_coeffs = new_coeffs;

    next_rom_addr = taps_addr[10:0];
    next_rom_data = taps_dina;
    if (tap_take == 1'b1) begin
        next_taps_dina = s_axis_reload_tdata[24:0];
        if (new_coeffs == 1'b1) begin
            next_taps_addr = 0;
            next_new_coeffs = 1'b0;
        end else begin
            next_taps_addr = taps_addr + 1;
            if (s_axis_reload_tlast == 1'b1) begin
                next_new_coeffs = 1'b1;
            end
        end
    end
    // implements the write address pointer for tap updates.
    if (tap_take_d1 == 1'b1) begin
        case (taps_addr[15:11])
            5'd0: next_taps_we = 32'd1;
            5'd1: next_taps_we = 32'd2;
            5'd2: next_taps_we = 32'd4;
            5'd3: next_taps_we = 32'd8;
            5'd4: next_taps_we = 32'd16;
            5'd5: next_taps_we = 32'd32;
            5'd6: next_taps_we = 32'd64;
            5'd7: next_taps_we = 32'd128;
            5'd8: next_taps_we = 32'd256;
            5'd9: next_taps_we = 32'd512;
            5'd10: next_taps_we = 32'd1024;
            5'd11: next_taps_we = 32'd2048;
            5'd12: next_taps_we = 32'd4096;
            5'd13: next_taps_we = 32'd8192;
            5'd14: next_taps_we = 32'd16384;
            5'd15: next_taps_we = 32'd32768;
            5'd16: next_taps_we = 32'd65536;
            5'd17: next_taps_we = 32'd131072;
            5'd18: next_taps_we = 32'd262144;
            5'd19: next_taps_we = 32'd524288;
            5'd20: next_taps_we = 32'd1048576;
            5'd21: next_taps_we = 32'd2097152;
            5'd22: next_taps_we = 32'd4194304;
            5'd23: next_taps_we = 32'd8388608;
            5'd24: next_taps_we = 32'd16777216;
            5'd25: next_taps_we = 32'd33554432;
            5'd26: next_taps_we = 32'd67108864;
            5'd27: next_taps_we = 32'd134217728;
            5'd28: next_taps_we = 32'd268435456;
            5'd29: next_taps_we = 32'd536870912;
            5'd30: next_taps_we = 32'd1073741824;
            5'd31: next_taps_we = 32'd2147483648;
            default: next_taps_we = 32'd0;
        endcase
    end else begin
        next_taps_we = 32'd0;
    end
end

// read and write address update logic.
always @*
begin
    next_offset_cnt = offset_cnt;
    next_offset_cnt_prev = offset_cnt_prev;
    next_rd_addr = rd_addr;
    next_wr_addr = wr_addr;
    // increment offset count once per cycle through the PFB arms.
    if (tvalid_d[2] == 1'b1) begin
        if (phase_mux_d[2] == 11'd0) begin
            next_offset_cnt_prev = offset_cnt;
            next_offset_cnt = offset_cnt + 1;
            next_wr_addr = {offset_cnt + 1, phase_mux_d[2]};
            next_rd_addr = {offset_cnt, phase_mux_d[2]};
        end else begin
            next_rd_addr = {offset_cnt_prev, phase_mux_d[2]};
            next_wr_addr = {offset_cnt, phase_mux_d[2]};
        end
    end

    if (tvalid_d[2] == 1'b1) begin
        if (bot_half == 1'b1) begin
            next_sig = delay_sig;
        end else begin
            next_sig = input_sig_d3;
        end
    end else begin
        next_sig = sig;
    end

    // shift through old values.
    if (tvalid_d[2] == 1'b1) begin
        next_rd_addr_d[0] = rd_addr;
        for (n=1; n<31; n=n+1) begin
            next_rd_addr_d[n] = rd_addr_d[n-1];
        end
    end else begin
        for (n=0; n<31; n=n+1) begin
            next_rd_addr_d[n] = rd_addr_d[n];
        end
    end
end

// 3 cycle latency.
dp_block_read_first_ram #(
  .DATA_WIDTH(32),
  .ADDR_WIDTH(11))
sample_delay (
  .clk(clk), 
  .wea(tvalid_d[0]),
  .addra(phase_mux_d[0][10:0]),
  .dia(input_sig_d1),
  .addrb(phase[10:0]),
  .dob(delay_sig)
);

// 3 cycle latency
dp_block_read_first_ram #(
  .DATA_WIDTH(32),
  .ADDR_WIDTH(13))
sample_ram_0 (
  .clk(clk), 
  .wea(tvalid_d[6]), 
  .addra(wr_addr_d[2][12:0]),
  .dia(sig_d3), 
  .addrb(rd_addr[12:0]),
  .dob(delay[0])
);

genvar i;
generate
    for (i=1; i<32; i=i+1) begin : TAP_DELAY
        dp_block_read_first_ram #(
          .DATA_WIDTH(32),
          .ADDR_WIDTH(13))
        sample_ram_inst (
          .clk(clk), 
          .wea(tvalid_d[6]), 
          .addra(wr_addr_d[i*3+2][12:0]), 
          .dia(delay[i-1]), 
          .addrb(rd_addr_d[i-1][12:0]),
          .dob(delay[i])
        );
    end
endgenerate

// Coefficent memories
// latency = 3.
dp_block_write_first_ram #(
    .DATA_WIDTH(25),
    .ADDR_WIDTH(11))
pfb_taps_0 (
    .clk(clk),
    .wea(taps_we[0]),
    .addra(rom_addr[10:0]),
    .dia(rom_data),
    .addrb(rd_addr[10:0]),
    .dob(taps[0])
);

genvar nn;
generate
    for (nn=1; nn<32; nn=nn+1) begin : COEFFS
        dp_block_write_first_ram #(
            .DATA_WIDTH(25),
            .ADDR_WIDTH(11))
        pfb_taps_nn
        (
            .clk(clk),
            .wea(taps_we[nn]),
            .addra(rom_addr[10:0]),
            .dia(rom_data),
            .addrb(rd_addr_d[nn-1][10:0]),
            .dob(taps[nn])
        );
    end
endgenerate


// PFB MAC blocks
dsp48_pfb_mac_0 pfb_mac_i_start (
  .clk(clk),
  .ce(tvalid_d[6]),
  .a(taps[0]),
  .b(delay[0][31:16]),
  .pcout(pcouti[0]), 
  .p()
);

// Latency = 4
dsp48_pfb_mac_0 pfb_mac_q_start (
  .clk(clk),
  .ce(tvalid_d[6]),
  .a(taps[0]), 
  .b(delay[0][15:0]),
  .pcout(pcoutq[0]), 
  .p()
);

genvar j;
generate
    for (j=1; j<32; j=j+1) begin : MAC
        dsp48_pfb_mac pfb_mac_i
        (
          .clk(clk),
          .ce(tvalid_d[6]),
          .pcin(pcouti[j-1]),
          .a(taps[j]),
          .b(delay[j][31:16]),
          .pcout(pcouti[j]),
          .p()
        );

        dsp48_pfb_mac pfb_mac_q
        (
          .clk(clk),
          .ce(tvalid_d[6]),
          .pcin(pcoutq[j-1]),
          .a(taps[j]),
          .b(delay[j][15:0]),
          .pcout(pcoutq[j]),
          .p()
        );
    end
endgenerate

dsp48_pfb_rnd pfb_rnd_i (
  .clk(clk),
  .ce(tvalid_d[6]),
  .pcin(pcouti[31]),
  .p(pouti)
);

dsp48_pfb_rnd pfb_rnd_q (
  .clk(clk),
  .ce(tvalid_d[6]),
  .pcin(pcoutq[31]),
  .p(poutq)
);

axi_fifo_3 #(
    .DATA_WIDTH(43),
    .ALMOST_FULL_THRESH(16),
    .ADDR_WIDTH(6))
u_fifo
(
    .clk(clk),
    .sync_reset(sync_reset),

    .s_axis_tvalid(fifo_tvalid),
    .s_axis_tdata(fifo_tdata),
    .s_axis_tlast(tlast_d[42]),
    .s_axis_tready(),

    .almost_full(almost_full),

    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tdata(m_axis_tdata_s),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tready(m_axis_tready)
);

endmodule
