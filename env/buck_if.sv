//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: 包接口 (valid/ready + keep/last 的多 beat 传输)
//
//     时序约定:
//       1. 一个包由 N 个 beat 组成, N = ceil(len/BPB), BPB = DW/8
//       2. 每个 beat 在 valid && ready 同时为高的时钟沿被接收
//       3. keep 为字节使能, 非末 beat 必须全 1, 末 beat 允许部分有效(低位对齐)
//       4. last 在包的最后一个 beat 拉高
//       5. 实际搬运字节数 = sum(popcount(keep)) over all beats
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_IF__SV
`define BUCK_IF__SV

interface buck_if #(parameter DW = 32) (input bit clk, input bit rst_n);

    localparam BPB = DW / 8;   // 每 beat 字节数

    logic           valid;
    logic           ready;
    logic [DW-1:0]  data;
    logic [BPB-1:0] keep;
    logic           last;

    // DUT 统计回读, 供 monitor 在 report_phase 自检
    logic [31:0]    dut_pkt_cnt;
    logic [31:0]    dut_byte_cnt;
    logic [31:0]    dut_beat_cnt;
    logic           dut_err_keep;

    clocking drv_cb @(posedge clk);
        output valid, data, keep, last;
        input  ready;
    endclocking

    clocking mon_cb @(posedge clk);
        input valid, ready, data, keep, last;
    endclocking

endinterface: buck_if

`endif // BUCK_IF__SV
