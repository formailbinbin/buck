//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo DUT: 一个带内部 FIFO 的 valid/ready sink (多 beat 包接口)
//
//     接口时序:
//       in_valid/in_ready 握手, 每次握手搬运一个 beat
//       in_keep 为字节使能, 实际搬运字节数 = popcount(in_keep)
//       in_last 标记包的最后一个 beat
//
//     用途: 作为令牌桶发包器的接收端, FIFO 近满时拉低 ready, 以便观察流量整形效果
//////////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module buck_sink #(
    parameter DW         = 32,
    parameter FIFO_DEPTH = 16,
    // 每隔 DRAIN_PERIOD 个时钟从 FIFO 排空一个 beat, 模拟下游处理能力
    parameter DRAIN_PERIOD = 8
) (
    input  wire              clk,
    input  wire              rst_n,

    // 输入包接口
    input  wire              in_valid,
    output wire              in_ready,
    input  wire [DW-1:0]     in_data,
    input  wire [DW/8-1:0]   in_keep,
    input  wire              in_last,

    // 统计输出
    output reg  [31:0]       pkt_cnt,     // 收到的完整包数(按 last 计)
    output reg  [31:0]       byte_cnt,    // 实际搬运字节数(按 keep 计)
    output reg  [31:0]       beat_cnt,    // 握手成功的 beat 数
    output wire [31:0]       fifo_level,
    output reg  [31:0]       drop_cnt,    // 背压次数(观测用)
    output reg               err_keep     // 协议错: 非末 beat 的 keep 不是全 1, 或 keep 全 0
);

    localparam BPB   = DW / 8;
    localparam PTR_W = $clog2(FIFO_DEPTH) + 1;

    reg [DW-1:0]    fifo_data [0:FIFO_DEPTH-1];
    reg [BPB-1:0]   fifo_keep [0:FIFO_DEPTH-1];
    reg             fifo_last [0:FIFO_DEPTH-1];
    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;

    wire [PTR_W-1:0] level = wr_ptr - rd_ptr;
    wire full  = (level == FIFO_DEPTH);
    wire empty = (level == 0);

    assign fifo_level = {{(32-PTR_W){1'b0}}, level};
    assign in_ready   = ~full;

    // keep 的 1 的个数 = 本 beat 的有效字节数
    integer bi;
    reg [7:0] keep_ones;
    always @(*) begin
        keep_ones = 8'd0;
        for (bi = 0; bi < BPB; bi = bi + 1)
            keep_ones = keep_ones + in_keep[bi];
    end

    // 非末 beat 必须满 keep; 任何 beat 的 keep 不得全 0
    wire keep_bad = (in_keep == {BPB{1'b0}}) ||
                    (!in_last && (in_keep != {BPB{1'b1}}));

    // 写入
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr   <= 0;
            pkt_cnt  <= 32'd0;
            byte_cnt <= 32'd0;
            beat_cnt <= 32'd0;
            drop_cnt <= 32'd0;
            err_keep <= 1'b0;
        end
        else begin
            if (in_valid && in_ready) begin
                fifo_data[wr_ptr[PTR_W-2:0]] <= in_data;
                fifo_keep[wr_ptr[PTR_W-2:0]] <= in_keep;
                fifo_last[wr_ptr[PTR_W-2:0]] <= in_last;
                wr_ptr   <= wr_ptr + 1'b1;
                beat_cnt <= beat_cnt + 32'd1;
                byte_cnt <= byte_cnt + {24'd0, keep_ones};
                if (in_last)
                    pkt_cnt <= pkt_cnt + 32'd1;
                if (keep_bad)
                    err_keep <= 1'b1;
            end
            // valid 但 ready 为低: 统计背压次数(非真正丢包, 仅观测用)
            if (in_valid && !in_ready)
                drop_cnt <= drop_cnt + 32'd1;
        end
    end

    // 按固定节奏排空, 代表下游带宽上限
    reg [15:0] drain_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr    <= 0;
            drain_cnt <= 16'd0;
        end
        else begin
            if (drain_cnt == DRAIN_PERIOD - 1) begin
                drain_cnt <= 16'd0;
                if (!empty)
                    rd_ptr <= rd_ptr + 1'b1;
            end
            else begin
                drain_cnt <= drain_cnt + 16'd1;
            end
        end
    end

endmodule
