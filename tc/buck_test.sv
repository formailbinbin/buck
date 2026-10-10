//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: testcase
//
//     tc_buck_base    : 基础 test, 速率 10 MB/s
//     tc_buck_rate    : 低速率 1 MB/s, 验证整形精度
//     tc_buck_burst   : 大桶深, 验证突发能力
//     tc_buck_pps     : 按 pps 限速
//     tc_buck_shared  : 两条 sequence 共享一个桶, 验证总流量受限
//     tc_buck_beatgap : 包内 beat 之间插随机空隙, 验证整形与协议不受影响
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_TEST__SV
`define BUCK_TEST__SV

class tc_buck_base extends uvm_test;

    buck_env         env;
    token_bucket_cfg bkt_cfg;

    `uvm_component_utils(tc_buck_base)

    function new(string name = "tc_buck_base", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 派生类重载以改配置
    virtual function void set_bucket_cfg();
        bkt_cfg.rate_tokens_per_sec = 10.0e6;   // 10 MB/s
        bkt_cfg.bucket_size         = 1024.0;   // 1KB 突发
        bkt_cfg.init_tokens         = -1.0;     // 初始装满
    endfunction

    virtual function int unsigned get_num_items();
        int unsigned n;
        int unsigned arg;
        n = 200;
        // 可用 +NUM_ITEMS=<n> 覆盖, 便于观察长窗口下平均速率的收敛
        // 注意: 必须判断返回值, plusarg 不存在时不可信赖目标变量保持原值
        if ($value$plusargs("NUM_ITEMS=%d", arg))
            n = arg;
        return n;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        bkt_cfg = token_bucket_cfg::type_id::create("bkt_cfg");
        set_bucket_cfg();
        uvm_config_db#(token_bucket_cfg)::set(this, "env", "bkt_cfg", bkt_cfg);

        env = buck_env::type_id::create("env", this);
    endfunction

    virtual task run_seq(uvm_phase phase);
        token_bucket_sequence seq;
        seq = token_bucket_sequence::type_id::create("seq");
        seq.num_items = get_num_items();
        seq.bucket    = env.bucket;
        seq.start(env.agent.sequencer);
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_seq(phase);
        // 等待最后几个包流过 DUT
        #1us;
        phase.drop_objection(this);
    endtask

    // 派生类可重载以改用别的判定口径
    virtual function void print_result();
        real cfg_rate, got_rate, err_pct;

        cfg_rate = bkt_cfg.rate_tokens_per_sec;
        got_rate = env.agent.monitor.measured_Bps();
        err_pct  = (cfg_rate > 0.0) ? (got_rate / cfg_rate - 1.0) * 100.0 : 0.0;

        `uvm_info("TC_RESULT", $sformatf(
            "\n================ %s result ================\n  configured : %.3e byte/s\n  measured   : %.3e byte/s\n  error      : %.2f pct\n===========================================",
            get_type_name(), cfg_rate, got_rate, err_pct), UVM_LOW)
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        print_result();
    endfunction

endclass: tc_buck_base


// 低速率: 整形误差应更小
class tc_buck_rate extends tc_buck_base;

    `uvm_component_utils(tc_buck_rate)

    function new(string name = "tc_buck_rate", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void set_bucket_cfg();
        bkt_cfg.rate_tokens_per_sec = 1.0e6;    // 1 MB/s
        bkt_cfg.bucket_size         = 512.0;
        bkt_cfg.init_tokens         = 0.0;      // 从空桶开始, 避免初始突发影响测量
    endfunction

    virtual function int unsigned get_num_items();
        return 100;
    endfunction

endclass: tc_buck_rate


// 大桶深: 允许先突发一大串再被限速
//
// 令牌桶的契约是 cost <= R*T + B, 而不是"平均速率恒等于 R"。
// 初始桶装满 B=8192, 这部分是零时刻即可用的突发信用, 若把它摊进平均速率,
// 误差必然是 B/(total-B) = 8192/19945 = 41%, 这是测量方法的问题, 不是整形失准。
//
// 因此本 case 不看含突发的平均速率, 改看两个真正有意义的指标:
//   1. steady_rate  : 突发信用耗尽后的稳态速率, 应收敛到 R
//   2. is_conformant: 实际用掉的突发信用不得超过桶深 B
class tc_buck_burst extends tc_buck_base;

    `uvm_component_utils(tc_buck_burst)

    function new(string name = "tc_buck_burst", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void set_bucket_cfg();
        bkt_cfg.rate_tokens_per_sec = 2.0e6;     // 2 MB/s
        bkt_cfg.bucket_size         = 8192.0;    // 8KB 大突发
        bkt_cfg.init_tokens         = -1.0;      // 装满 -> 开场即突发
    endfunction

    virtual function void print_result();
        real cfg_rate, raw_rate, std_rate, raw_err, std_err;

        cfg_rate = bkt_cfg.rate_tokens_per_sec;
        raw_rate = env.bucket.measured_rate();
        std_rate = env.bucket.steady_rate();
        raw_err  = (raw_rate / cfg_rate - 1.0) * 100.0;
        std_err  = (std_rate / cfg_rate - 1.0) * 100.0;

        // 稳态速率必须收敛到配置速率
        if (!env.bucket.steady_available()) begin
            `uvm_error("TC_BURST", "steady state never reached, cannot judge shaping accuracy")
        end
        else if (std_err > 5.0 || std_err < -5.0) begin
            `uvm_error("TC_BURST", $sformatf("steady rate error %.2f pct exceeds 5 pct", std_err))
        end

        // 用掉的突发量不得超过桶深
        if (!env.bucket.is_conformant()) begin
            `uvm_error("TC_BURST", $sformatf("burst used %.1f exceeds bucket_size %.1f",
                                            env.bucket.max_excess, bkt_cfg.bucket_size))
        end

        `uvm_info("TC_RESULT", $sformatf(
            "\n================ %s result ================\n  configured   : %.3e byte/s\n  raw avg      : %.3e byte/s (err %.2f pct, 含开场突发, 仅供参考)\n  steady       : %.3e byte/s (err %.2f pct)\n  burst used   : %.1f / %.1f byte\n  conformant   : %s\n===========================================",
            get_type_name(), cfg_rate, raw_rate, raw_err, std_rate, std_err,
            env.bucket.max_excess, bkt_cfg.bucket_size,
            env.bucket.is_conformant() ? "YES" : "NO"), UVM_LOW)
    endfunction

endclass: tc_buck_burst


// 按 pps 限速
class tc_buck_pps extends tc_buck_base;

    `uvm_component_utils(tc_buck_pps)

    function new(string name = "tc_buck_pps", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void set_bucket_cfg();
        bkt_cfg.rate_tokens_per_sec = 100.0e3;   // 100 Kpps
        bkt_cfg.bucket_size         = 16.0;      // 最多攒 16 个包的突发
        bkt_cfg.init_tokens         = 0.0;
    endfunction

    virtual task run_seq(uvm_phase phase);
        tb_pps_sequence seq;
        seq = tb_pps_sequence::type_id::create("seq");
        seq.num_items = 200;
        seq.bucket    = env.bucket;
        seq.start(env.agent.sequencer);
    endtask

    virtual function void print_result();
        real cfg_rate, got_rate, err_pct;
        cfg_rate = bkt_cfg.rate_tokens_per_sec;
        got_rate = env.agent.monitor.measured_pps();
        err_pct  = (cfg_rate > 0.0) ? (got_rate / cfg_rate - 1.0) * 100.0 : 0.0;

        `uvm_info("TC_RESULT", $sformatf(
            "\n================ %s result ================\n  configured : %.3e pkt/s\n  measured   : %.3e pkt/s\n  error      : %.2f pct\n===========================================",
            get_type_name(), cfg_rate, got_rate, err_pct), UVM_LOW)
    endfunction

endclass: tc_buck_pps


// 两条 sequence 共享一个桶: 总速率仍应被限制在配置值
class tc_buck_shared extends tc_buck_base;

    `uvm_component_utils(tc_buck_shared)

    function new(string name = "tc_buck_shared", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void set_bucket_cfg();
        bkt_cfg.rate_tokens_per_sec = 4.0e6;    // 两条流共享 4 MB/s
        bkt_cfg.bucket_size         = 1024.0;
        bkt_cfg.init_tokens         = 0.0;
    endfunction

    virtual task run_seq(uvm_phase phase);
        token_bucket_sequence seq0, seq1;
        seq0 = token_bucket_sequence::type_id::create("seq0");
        seq1 = token_bucket_sequence::type_id::create("seq1");
        seq0.num_items = 100;
        seq1.num_items = 100;
        seq0.bucket    = env.bucket;
        seq1.bucket    = env.bucket;

        // 两条 sequence 并发抢同一个桶的令牌
        fork
            seq0.start(env.agent.sequencer);
            seq1.start(env.agent.sequencer);
        join
    endtask

endclass: tc_buck_shared


// 包内空隙: beat 之间随机插入空闲拍, 验证令牌桶整形不受总线微观节奏影响
//
// driver 用 factory 换成 buck_gap_driver, 其余配置与 base 相同。
// 包内空隙会把单包的搬运时间拉长, 从而推后下一次 consume() 的调用时刻,
// 这在墙钟窗口上表现为 raw/steady 偏低 —— 它们的分母无法区分
// "等令牌" 与 "等总线", 因此本 case 不以速率为判据, 只卡两件事:
//   1. 符合性: 任意窗口放行量不超过 R*T + B, 与窗口口径无关, 恒成立
//   2. 协议与计数: monitor 的 beat/byte 自检及与 DUT 的对账必须一致
//      (由 monitor 自身在 report_phase 完成)
class tc_buck_beatgap extends tc_buck_base;

    `uvm_component_utils(tc_buck_beatgap)

    function new(string name = "tc_buck_beatgap", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        buck_driver::type_id::set_type_override(buck_gap_driver::get_type());
        super.build_phase(phase);
    endfunction

    virtual function void set_bucket_cfg();
        bkt_cfg.rate_tokens_per_sec = 10.0e6;   // 10 MB/s, 同 base
        bkt_cfg.bucket_size         = 1024.0;
        bkt_cfg.init_tokens         = 0.0;      // 从空桶开始
    endfunction

    virtual function void print_result();
        real cfg_rate, raw_rate;

        cfg_rate = bkt_cfg.rate_tokens_per_sec;
        raw_rate = env.bucket.measured_rate();

        if (!env.bucket.is_conformant()) begin
            `uvm_error("TC_BEATGAP", $sformatf("burst used %.1f exceeds bucket_size %.1f",
                                              env.bucket.max_excess, bkt_cfg.bucket_size))
        end

        `uvm_info("TC_RESULT", $sformatf(
            "\n================ %s result ================\n  configured   : %.3e byte/s\n  raw avg      : %.3e byte/s (含包内空隙, 仅供参考)\n  burst used   : %.1f / %.1f byte\n  conformant   : %s\n===========================================",
            get_type_name(), cfg_rate, raw_rate,
            env.bucket.max_excess, bkt_cfg.bucket_size,
            env.bucket.is_conformant() ? "YES" : "NO"), UVM_LOW)
    endfunction

endclass: tc_buck_beatgap

`endif // BUCK_TEST__SV
