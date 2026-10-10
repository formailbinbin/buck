//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: driver, 按 valid/ready 握手逐 beat 驱动一个包
//
//     一个包拆成 ceil(len/BPB) 个 beat 发出:
//       非末 beat: keep 全 1, last = 0
//       末   beat: keep 低位对齐地标出剩余字节, last = 1
//     令牌已由 sequence 在整包第一拍之前一次性扣掉, driver 只负责搬数据
//
//     beat 之间默认背靠背; 重载 beat_gap() 可插入包内空隙(见 buck_gap_driver)
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_DRIVER__SV
`define BUCK_DRIVER__SV

class buck_driver extends uvm_driver #(buck_transaction);

    virtual buck_if vif;

    `uvm_component_utils(buck_driver)

    function new(string name = "buck_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual buck_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "virtual interface must be set for buck_driver.vif")
    endfunction

    task run_phase(uvm_phase phase);
        // 复位期间先把总线置为空闲
        vif.valid <= 1'b0;
        vif.data  <= '0;
        vif.keep  <= '0;
        vif.last  <= 1'b0;
        wait (vif.rst_n === 1'b1);

        forever begin
            seq_item_port.get_next_item(req);
            drive_one(req);
            seq_item_port.item_done();
        end
    endtask

    task drive_one(buck_transaction tr);
        int unsigned beats;
        int unsigned rem;
        bit [BUCK_DW-1:0]  beat_data;
        bit [BUCK_BPB-1:0] beat_keep;
        int unsigned b, i, idx;
        int unsigned gap;

        beats = tr.num_beats();

        @(vif.drv_cb);

        for (b = 0; b < beats; b++) begin
            // 本 beat 的有效字节数
            rem = tr.len - b * BUCK_BPB;
            if (rem > BUCK_BPB) rem = BUCK_BPB;

            beat_data = '0;
            beat_keep = '0;
            for (i = 0; i < rem; i++) begin
                idx = b * BUCK_BPB + i;
                beat_data[i*8 +: 8] = tr.payload[idx];
                beat_keep[i]        = 1'b1;
            end

            vif.drv_cb.valid <= 1'b1;
            vif.drv_cb.data  <= beat_data;
            vif.drv_cb.keep  <= beat_keep;
            vif.drv_cb.last  <= (b == beats - 1);

            // 等到本 beat 被对端接收
            do begin
                @(vif.drv_cb);
            end while (vif.drv_cb.ready !== 1'b1);

            // 包内空隙: 只能插在握手完成之后。valid 一旦拉高, 在 ready 到来前
            // 不得回撤(valid/ready 协议硬性要求), 否则在真实 IP 上会违例。
            // 末 beat 之后不插 —— 包间节奏由令牌桶负责。
            if (b != beats - 1) begin
                gap = beat_gap(tr, b);
                if (gap > 0) begin
                    vif.drv_cb.valid <= 1'b0;
                    vif.drv_cb.keep  <= '0;
                    vif.drv_cb.last  <= 1'b0;
                    repeat (gap) @(vif.drv_cb);
                end
            end
        end

        vif.drv_cb.valid <= 1'b0;
        vif.drv_cb.last  <= 1'b0;
        vif.drv_cb.keep  <= '0;

        `uvm_info("BUCK_DRV", $sformatf("sent pkt len=%0d beats=%0d", tr.len, beats), UVM_HIGH)
    endtask

    // 第 idx 个 beat 握手完成后插入的空闲拍数, 0 表示与下一 beat 背靠背。
    // 默认不插, 保证已有 case 的时序不变。
    virtual function int unsigned beat_gap(buck_transaction tr, int unsigned idx);
        return 0;
    endfunction

endclass: buck_driver


// 包内随机空隙的 driver
//
// 注意不要让每个 beat 都插空隙: 本 demo 的 DUT 排空速率是 4 byte/4ns,
// 恰为线速一半。背靠背输入(4 byte/2ns)才能把 FIFO 填满并触发背压;
// 若每拍都插隙, 输入降到排空速率以下, FIFO 永远填不满, 背压路径
// 与 driver 等 ready 的分支就都失去覆盖了。
// 因此概率上保留相当比例的 0, 让背靠背片段与空隙片段混合出现。
class buck_gap_driver extends buck_driver;

    // 插入空隙的概率(百分比), 其余情况背靠背
    int unsigned gap_percent = 40;
    // 空隙拍数范围
    int unsigned gap_min     = 1;
    int unsigned gap_max     = 3;

    `uvm_component_utils(buck_gap_driver)

    function new(string name = "buck_gap_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function int unsigned beat_gap(buck_transaction tr, int unsigned idx);
        if ($urandom_range(1, 100) > gap_percent) return 0;
        return $urandom_range(gap_min, gap_max);
    endfunction

endclass: buck_gap_driver

`endif // BUCK_DRIVER__SV
