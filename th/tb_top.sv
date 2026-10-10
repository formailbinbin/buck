//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: testbench top
//////////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module tb_top;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import buck_pkg::*;

    parameter DW = 32;

    bit clk;
    bit rst_n;

    // 500MHz, 周期 2ns
    initial begin
        clk = 0;
        forever #1ns clk = ~clk;
    end

    initial begin
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
    end

    buck_if #(.DW(DW)) pkt_if (.clk(clk), .rst_n(rst_n));

    wire [31:0] pkt_cnt;
    wire [31:0] byte_cnt;
    wire [31:0] beat_cnt;
    wire [31:0] fifo_level;
    wire [31:0] drop_cnt;
    wire        err_keep;

    buck_sink #(
        .DW          (DW),
        .FIFO_DEPTH  (16),
        .DRAIN_PERIOD(2)
    ) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (pkt_if.valid),
        .in_ready  (pkt_if.ready),
        .in_data   (pkt_if.data),
        .in_keep   (pkt_if.keep),
        .in_last   (pkt_if.last),
        .pkt_cnt   (pkt_cnt),
        .byte_cnt  (byte_cnt),
        .beat_cnt  (beat_cnt),
        .fifo_level(fifo_level),
        .drop_cnt  (drop_cnt),
        .err_keep  (err_keep)
    );

    // DUT 统计回读给 monitor 做自检
    assign pkt_if.dut_pkt_cnt  = pkt_cnt;
    assign pkt_if.dut_byte_cnt = byte_cnt;
    assign pkt_if.dut_beat_cnt = beat_cnt;
    assign pkt_if.dut_err_keep = err_keep;

    initial begin
        uvm_config_db#(virtual buck_if)::set(null, "uvm_test_top.env.agent.*", "vif", pkt_if);
        run_test();
    end

    // 波形
    initial begin
        if ($test$plusargs("FSDB")) begin
            $fsdbDumpfile("tb_top.fsdb");
            $fsdbDumpvars(0, tb_top, "+all");
        end
    end

    // 超时保护, 可用 +TIMEOUT_MS=<n> 覆盖
    // 注意: 低速率 + 大包的 case 需要较长仿真时间, 例如 1MB/s 发 100 个平均 136B 的包约需 13.6ms
    initial begin
        int unsigned timeout_ms;
        timeout_ms = 50;
        void'($value$plusargs("TIMEOUT_MS=%d", timeout_ms));
        #(timeout_ms * 1ms);
        `uvm_fatal("TIMEOUT", $sformatf("simulation timeout at %0dms", timeout_ms))
    end

endmodule: tb_top
