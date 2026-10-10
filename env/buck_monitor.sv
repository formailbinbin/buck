//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: monitor
//       - 逐 beat 采样, 按 last 聚包
//       - 用 popcount(keep) 累加真实字节数, 并与包内 beat 数做协议自检
//       - 做速率统计(byte/s, pkt/s)
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_MONITOR__SV
`define BUCK_MONITOR__SV

class buck_monitor extends uvm_monitor;

    virtual buck_if vif;

    uvm_analysis_port #(buck_transaction) ap;

    // 速率统计
    int unsigned     pkt_cnt;
    int unsigned     beat_cnt;
    longint unsigned byte_cnt;
    realtime         first_time;
    realtime         last_time;

    // 协议错误计数
    int unsigned keep_err_cnt;

    `uvm_component_utils(buck_monitor)

    function new(string name = "buck_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual buck_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "virtual interface must be set for buck_monitor.vif")
    endfunction

    task run_phase(uvm_phase phase);
        buck_transaction   tr;
        byte unsigned      bytes[$];
        bit [BUCK_DW-1:0]  bdata;
        bit [BUCK_BPB-1:0] bkeep;
        bit                blast;
        int unsigned       pkt_beats;
        int unsigned       i;

        wait (vif.rst_n === 1'b1);

        bytes.delete();
        pkt_beats = 0;

        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.valid !== 1'b1 || vif.mon_cb.ready !== 1'b1)
                continue;

            bdata = vif.mon_cb.data;
            bkeep = vif.mon_cb.keep;
            blast = vif.mon_cb.last;

            // 协议检查: keep 不得全 0; 非末 beat 必须满 keep
            if (bkeep == '0) begin
                keep_err_cnt++;
                `uvm_error("BUCK_MON", $sformatf("keep is all zero @%0t", $realtime))
            end
            else if (!blast && bkeep !== {BUCK_BPB{1'b1}}) begin
                keep_err_cnt++;
                `uvm_error("BUCK_MON", $sformatf("non-last beat with partial keep=0x%0h @%0t", bkeep, $realtime))
            end

            // 按 keep 收集真实字节
            for (i = 0; i < BUCK_BPB; i++)
                if (bkeep[i])
                    bytes.push_back(bdata[i*8 +: 8]);

            pkt_beats++;
            beat_cnt++;

            if (!blast)
                continue;

            // 末 beat: 组装成一个完整包
            tr = buck_transaction::type_id::create("tr");
            tr.len = bytes.size();
            tr.payload = new[bytes.size()];
            foreach (bytes[j]) tr.payload[j] = bytes[j];

            // 自检: beat 数必须与 len 相符
            if (pkt_beats != tr.num_beats()) begin
                `uvm_error("BUCK_MON", $sformatf("beat count mismatch: got %0d beats for len=%0d (expect %0d)",
                                                pkt_beats, tr.len, tr.num_beats()))
            end

            if (pkt_cnt == 0) first_time = $realtime;
            last_time = $realtime;
            pkt_cnt++;
            byte_cnt += tr.len;

            ap.write(tr);
            `uvm_info("BUCK_MON", $sformatf("observed pkt[%0d] len=%0d beats=%0d @%0t",
                                            pkt_cnt, tr.len, pkt_beats, $realtime), UVM_HIGH)

            bytes.delete();
            pkt_beats = 0;
        end
    endtask

    // 实测速率(byte/sec), 窗口取首包到末包
    function real measured_Bps();
        real span_s;
        if (pkt_cnt < 2) return 0.0;
        span_s = (last_time - first_time) / 1e9;  // timeunit=1ns
        if (span_s <= 0.0) return 0.0;
        return real'(byte_cnt) / span_s;
    endfunction

    function real measured_pps();
        real span_s;
        if (pkt_cnt < 2) return 0.0;
        span_s = (last_time - first_time) / 1e9;
        if (span_s <= 0.0) return 0.0;
        return real'(pkt_cnt) / span_s;
    endfunction

    // 与 DUT 内部统计对比
    function void check_vs_dut();
        if (vif.dut_err_keep === 1'b1)
            `uvm_error("BUCK_CHK", "DUT flagged keep protocol error")

        if (vif.dut_pkt_cnt !== pkt_cnt)
            `uvm_error("BUCK_CHK", $sformatf("pkt_cnt mismatch: dut=%0d monitor=%0d", vif.dut_pkt_cnt, pkt_cnt))

        if (vif.dut_beat_cnt !== beat_cnt)
            `uvm_error("BUCK_CHK", $sformatf("beat_cnt mismatch: dut=%0d monitor=%0d", vif.dut_beat_cnt, beat_cnt))

        if (vif.dut_byte_cnt !== byte_cnt)
            `uvm_error("BUCK_CHK", $sformatf("byte_cnt mismatch: dut=%0d monitor=%0d", vif.dut_byte_cnt, byte_cnt))

        `uvm_info("BUCK_CHK", $sformatf("dut vs monitor: pkt=%0d/%0d beat=%0d/%0d byte=%0d/%0d",
                  vif.dut_pkt_cnt, pkt_cnt, vif.dut_beat_cnt, beat_cnt, vif.dut_byte_cnt, byte_cnt), UVM_LOW)
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        check_vs_dut();
        `uvm_info("BUCK_MON", $sformatf(
            "\n---------------- monitor summary ----------------\n  pkt_cnt      = %0d\n  beat_cnt     = %0d\n  byte_cnt     = %0d\n  avg pkt len  = %.1f byte\n  window       = %.3f us\n  rate         = %.2f MB/s\n  rate         = %.2f Mpps\n  keep_err     = %0d\n-------------------------------------------------",
            pkt_cnt, beat_cnt, byte_cnt,
            (pkt_cnt > 0) ? real'(byte_cnt) / real'(pkt_cnt) : 0.0,
            (last_time - first_time) / 1000.0,
            measured_Bps() / 1e6, measured_pps() / 1e6, keep_err_cnt), UVM_LOW)
    endfunction

endclass: buck_monitor

`endif // BUCK_MONITOR__SV
