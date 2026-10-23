//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: agent + env
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_ENV__SV
`define BUCK_ENV__SV

class buck_agent extends uvm_agent;

    buck_driver                          driver;
    buck_monitor                         monitor;
    uvm_sequencer #(buck_transaction)    sequencer;

    `uvm_component_utils(buck_agent)

    function new(string name = "buck_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor = buck_monitor::type_id::create("monitor", this);
        if (get_is_active() == UVM_ACTIVE) begin
            driver    = buck_driver::type_id::create("driver", this);
            sequencer = uvm_sequencer#(buck_transaction)::type_id::create("sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass: buck_agent


class buck_env extends uvm_env;

    buck_agent       agent;
    buck_win_stats   win_stats;
    token_bucket     bucket;
    token_bucket_cfg bkt_cfg;

    `uvm_component_utils(buck_env)

    function new(string name = "buck_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // 若 test 没有注入配置, 用默认值兜底
        if (!uvm_config_db#(token_bucket_cfg)::get(this, "", "bkt_cfg", bkt_cfg)) begin
            bkt_cfg = token_bucket_cfg::type_id::create("bkt_cfg");
            `uvm_info("BUCK_ENV", "no bkt_cfg from config_db, use default", UVM_LOW)
        end

        agent     = buck_agent::type_id::create("agent", this);
        win_stats = buck_win_stats::type_id::create("win_stats", this);

        bucket = token_bucket::type_id::create("bucket");
        bucket.configure(bkt_cfg);

        // 发布到 config_db, 供 sequence 取用; 作用域覆盖 sequencer 下所有 sequence
        uvm_config_db#(token_bucket)::set(null, "*", "tb_bucket", bucket);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.monitor.ap.connect(win_stats.analysis_export);
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        bucket.print_stats("(env)");
    endfunction

endclass: buck_env

`endif // BUCK_ENV__SV
