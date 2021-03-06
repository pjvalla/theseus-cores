`timescale 1ns/1ps
`define NS_PER_TICK 1
`define NUM_TEST_CASES 5

`define SEEK_SET 0
`define SEEK_CUR 1
`define SEEK_END 2
`define INCL_BIN_WR 1

`include "sim_exec_report.vh"
`include "sim_rfnoc_lib.svh"
// `include "chan_rfnoc_sim.vh"

module noc_block_channelizer_tb();
  `TEST_BENCH_INIT("noc_block_channelizer",`NUM_TEST_CASES,`NS_PER_TICK);
  localparam BUS_CLK_PERIOD = $ceil(1e9/200e6);
  localparam CE_CLK_PERIOD  = $ceil(1e9/215e6);
  localparam NUM_CE         = 1;  // Number of Computation Engines / User RFNoC blocks to simulate
  localparam NUM_STREAMS    = 1;  // Number of test bench streams
  `RFNOC_SIM_INIT(NUM_CE, NUM_STREAMS, BUS_CLK_PERIOD, CE_CLK_PERIOD);
  `RFNOC_ADD_BLOCK(noc_block_channelizer, 0);

  localparam SPP = 1024; // Samples per packet  Had STOP Flow issue when using 16.
  localparam [31:0] FFT_SIZE = 32'd8;
  localparam [31:0] AVG_LEN = 32'd16;
  localparam [31:0] PKT_SIZE = 32'd750;

  /********************************************************
  ** Verification
  ********************************************************/
  initial begin : tb_main
    string s;
    logic [31:0] random_word;
    logic [63:0] readback;
    int num_taps;
    int in_file;
    int fd_int;
    int fd_coeffs;
    int fd_mask;
    int file_size;
    int num_words;
    int temp;
    int offset;
    // int position = 0;
    /********************************************************
    ** Test 1 -- Reset
    ********************************************************/
    `TEST_CASE_START("Wait for Reset");
    while (bus_rst) @(posedge bus_clk);
    while (ce_rst) @(posedge ce_clk);
    `TEST_CASE_DONE(~bus_rst & ~ce_rst);

    /********************************************************
    ** Test 2 -- Check for correct NoC IDs
    ********************************************************/
    `TEST_CASE_START("Check NoC ID");
    // Read NOC IDs
    tb_streamer.read_reg(sid_noc_block_channelizer, RB_NOC_ID, readback);
    $display("Read Frame Detect NOC ID: %16x", readback);
    `ASSERT_ERROR(readback == noc_block_channelizer.NOC_ID, "Incorrect NOC ID");
    `TEST_CASE_DONE(1);

    tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_FFT_SIZE, FFT_SIZE);
    tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_AVG_LEN, AVG_LEN);
    tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_PKT_SIZE, PKT_SIZE);


    /********************************************************
    ** Test 3 -- Connect RFNoC blocks
    ********************************************************/
    `TEST_CASE_START("Connect RFNoC blocks");
    `RFNOC_CONNECT(noc_block_tb,noc_block_channelizer,SC16,SPP);
    `RFNOC_CONNECT(noc_block_channelizer,noc_block_tb,SC16,SPP);
    `TEST_CASE_DONE(1);
    /********************************************************
    ** Test 4 -- Load Registers
    ********************************************************/
    `TEST_CASE_START("Load Registers");
    begin
        tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_FFT_SIZE, FFT_SIZE);
        tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_AVG_LEN, AVG_LEN);
        tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_PKT_SIZE, PKT_SIZE);
    end

    `TEST_CASE_DONE(1);
    /********************************************************
    ** Test 5 -- Load Channel Mask
    ********************************************************/
    `TEST_CASE_START("Load Coefficients");
    fd_mask = $fopen("M_8_mask.bin", "r");
    $display("current file position = %d", $ftell(fd_mask));
    temp = $fseek(fd_mask, 0, `SEEK_END);
    file_size = $ftell(fd_mask) >> 2;  // this is in bytes / 4.
    offset = $fseek(fd_mask, 0, `SEEK_SET);
    $display("Mask - Current file position = %d", $ftell(fd_mask));
    $display("Mask : FileDescr = %d", fd_mask);
    $display("Mask File Size : %d", file_size);
    // seek back to the beginning of the file.
    offset = $fseek(fd_mask, 0, `SEEK_SET);
    $display("Mask - Current file position = %d", $ftell(fd_mask));
    // tb_streamer.read_reg(sid_noc_block_channelizer, RB_NOC_ID, readback);
    // $display("Read Frame Detect NOC ID: %16x", readback);
    /* Set filter coefficients via reload bus */
    begin
        int num_read;
        reg [31:0] data32;
        reg [31:0] memory;
        int file_idx;
        for (int i=0; i<file_size; i++) begin //file_size
              file_idx = $ftell(fd_mask);
              num_read = $fread(memory, fd_mask, file_idx, 1);
              if (i % 1000 == 0 && i != 0) begin
                $display("MASK - Current file position = %d", $ftell(fd_mask) / 4 - 1);
                $display("Current simulation time = %t",$time);
                // $display("Wall time = %s",$system("date"));
                $display("");
              end
              if (i == file_size-1) begin
                tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_MASK_RELOAD_LAST, memory);
              end else begin
                tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_MASK_RELOAD, memory);
              end
        end
    end

    `TEST_CASE_DONE(1);


    /********************************************************
    ** Test 5 -- Load Coefficients
    ********************************************************/
    `TEST_CASE_START("Load Coefficients");
    fd_coeffs = $fopen("M_8_taps.bin", "r");
    $display("current file position = %d", $ftell(fd_coeffs));
    temp = $fseek(fd_coeffs, 0, `SEEK_END);
    file_size = $ftell(fd_coeffs) >> 2;  // this is in bytes / 4.
    offset = $fseek(fd_coeffs, 0, `SEEK_SET);
    $display("Taps - Current file position = %d", $ftell(fd_coeffs));
    $display("Taps : FileDescr = %d", fd_coeffs);
    $display("Taps File Size : %d", file_size);
    // seek back to the beginning of the file.
    offset = $fseek(fd_coeffs, 0, `SEEK_SET);
    $display("Taps - Current file position = %d", $ftell(fd_coeffs));
    // tb_streamer.read_reg(sid_noc_block_channelizer, RB_NOC_ID, readback);
    // $display("Read Frame Detect NOC ID: %16x", readback);
    /* Set filter coefficients via reload bus */
    begin
        int num_read;
        reg [31:0] data32;
        reg [31:0] memory;
        int file_idx;
        for (int i=0; i<file_size; i++) begin //file_size
              file_idx = $ftell(fd_coeffs);
              num_read = $fread(memory, fd_coeffs, file_idx, 1);
              if (i % 1000 == 0 && i != 0) begin
                $display("Taps - Current file position = %d", $ftell(fd_coeffs) / 4 - 1);
                $display("Current simulation time = %t",$time);
                // $display("Wall time = %s",$system("date"));
                $display("");
              end
              if (i == file_size-1) begin
                tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_RELOAD_LAST, memory);
              end else begin
                tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_RELOAD, memory);
              end
        end
    end

    `TEST_CASE_DONE(1);


    /********************************************************
    ** Test 6 -- Test Channelizer
    ********************************************************/
    // Sending an impulse will readback the FIR filter coefficients
    `TEST_CASE_START("Test Channelizer");
    fd_int = $fopen("sig_tones_input.bin", "r");

    $display("current file position = %d", $ftell(fd_int));
    temp = $fseek(fd_int, 0, `SEEK_END);
    file_size = $ftell(fd_int) >> 4;  // ftell is in bytes
    num_words = file_size / SPP;
    offset = $fseek(fd_int, 0, `SEEK_SET);
    $display("Reader - current file position = %d", $ftell(fd_int));
    $display("Reader : FileDescr = %d",fd_int);
    $display("File Size : %d", file_size);
    // seek back to the beginning of the file.
    offset = $fseek(fd_int, 0, `SEEK_SET);
    $display("Reader - current file position = %d", $ftell(fd_int));
    tb_streamer.read_reg(sid_noc_block_channelizer, RB_NOC_ID, readback);
    $display("Read Frame Detect NOC ID: %16x", readback);

    fork
    begin
        int r;
        int eob;
        int num_read;
        cvita_payload_t send_payload;
        cvita_metadata_t md;
        reg [31:0] data32_0, data32_1;
        logic [63:0] data;
        reg [31:0] memory;
        int frame_end;
        int file_idx;
        // set fft_size to 16
        tb_streamer.write_reg(sid_noc_block_channelizer, noc_block_channelizer.SR_FFT_SIZE, FFT_SIZE);
        for (int i=0; i<num_words; i++) begin
            send_payload = {};
            for (int j=0; j<SPP; j++) begin
              file_idx = $ftell(fd_int);
              num_read = $fread(data32_0, fd_int, file_idx, 1);
              num_read = $fread(data32_1, fd_int, file_idx, 1);
              data = {data32_0, data32_1};
              if (i % 1000 == 0 && i != 0 && j == 0) begin
                $display("Input Data - Current file position = %d", $ftell(fd_int) / 4 - 1);
                $display("Current simulation time = %t", $time);
                // $display("Wall time = %s", $date);
                $display("");
              end
              send_payload.push_back(data);
            end
            md.eob = 1;
            tb_streamer.send(send_payload, md);
        end
    end
    begin
      cvita_metadata_t md;
      cvita_payload_t recv_payload;
      md.eob = 0;
      // AXI output port.
      while(1) begin
        while (~md.eob) tb_streamer.recv(recv_payload,md);
        md.eob = 0;
        #200ns;
      end

    end
    join
    `TEST_CASE_DONE(1);
    `TEST_BENCH_DONE;
  end
endmodule
