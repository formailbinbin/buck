//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: 基于令牌桶的发包 sequence
//
//     用法:
//       1. 继承后重载 item_cost() 决定流控单位(返回包长=控 byte/s, 返回 1=控 pps)
//       2. 重载 randomize_item() 加自定义约束
//       3. 通过 uvm_config_db#(token_bucket) 共享同一个桶可限制多 sequence 的总流量
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_SEQUENCE__SV
`define BUCK_SEQUENCE__SV

class token_bucket_sequence extends uvm_sequence #(buck_transaction);

    // 发包数, 0 表示持续发包直到被 kill
    int unsigned num_items = 100;

    // 流控桶, 可外部赋值或由 config_db 获取
    token_bucket bucket;

    // 桶的 config_db 查找名
    string bucket_name = "tb_bucket";

    `uvm_object_utils_begin(token_bucket_sequence)
        `uvm_field_int(num_items, UVM_ALL_ON | UVM_DEC)
    `uvm_object_utils_end

    function new(string name = "token_bucket_sequence");
        super.new(name);
    endfunction

    // 本 item 消耗的令牌数, 派生类可重载
    virtual function real item_cost(buck_transaction tr);
        return real'(tr.len);  // 默认按包长计费 -> 控 byte/s
    endfunction

    // 随机化钩子, 派生类可重载以加约束
    virtual function void randomize_item(buck_transaction tr);
        if (!tr.randomize())
            `uvm_error("RNDFAIL", "buck_transaction randomize failed")
    endfunction

    virtual task pre_body();
        // 优先用外部注入的桶, 否则从 config_db 取
        if (bucket == null) begin
            if (!uvm_config_db#(token_bucket)::get(null, get_full_name(), bucket_name, bucket))
                `uvm_fatal("NOBUCKET", $sformatf("token_bucket '%s' not found in config_db", bucket_name))
        end
    endtask

    virtual task body();
        buck_transaction tr;
        int unsigned i;

        `uvm_info("TB_SEQ", $sformatf("start sending, num_items=%0d", num_items), UVM_LOW)

        i = 0;
        forever begin
            if (num_items != 0 && i >= num_items) break;

            tr = buck_transaction::type_id::create($sformatf("tr_%0d", i));
            start_item(tr);
            randomize_item(tr);
            // 关键: 取到令牌后才放行, 从而把流量整形到配置速率
            bucket.consume(item_cost(tr));
            finish_item(tr);

            i++;
        end

        `uvm_info("TB_SEQ", $sformatf("done, sent %0d items", i), UVM_LOW)
    endtask

endclass: token_bucket_sequence


// 定长小包 + 按 pps 限速的派生示例
class tb_pps_sequence extends token_bucket_sequence;

    `uvm_object_utils(tb_pps_sequence)

    function new(string name = "tb_pps_sequence");
        super.new(name);
    endfunction

    // 每包固定消耗 1 个令牌 -> 速率单位为 packet/sec
    virtual function real item_cost(buck_transaction tr);
        return 1.0;
    endfunction

    virtual function void randomize_item(buck_transaction tr);
        if (!tr.randomize() with { len inside {[64:64]}; })
            `uvm_error("RNDFAIL", "tb_pps_sequence randomize failed")
    endfunction

endclass: tb_pps_sequence

`endif // BUCK_SEQUENCE__SV
