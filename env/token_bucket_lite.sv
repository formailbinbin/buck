//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: 令牌桶精简版(仅整形, 无统计)
//
//     与 token_bucket.sv 的算法完全一致, 只是剥掉了全部统计与自检:
//     无 grant_cnt / total_cost / measured_rate / is_conformant / print_stats。
//     适用于"只要把速率限住、不需要对速率下断言"的场景。
//     若需要 raw/steady 速率与符合性检查, 请用 token_bucket。
//
//     算法(GCRA 虚拟时间): 不维护"当前令牌数", 只维护 tat(理论到达时间)。
//         tokens(t) = bucket_size - (tat - t) * rate
//     放行条件 tokens >= cost 等价于 t >= tat - (bucket_size - cost)/rate,
//     故等待时间一次闭式算出, 无循环、无后台线程、无浮点累加漂移。
//     状态只有一个 real。
//
//     速率单位由调用方自定: item_cost 返回包长(byte) 则 rate 为 byte/sec;
//     item_cost 返回 1 则 rate 为 packet/sec。
//
//     单包 cost 超过桶深时自动延长等待并按实际 cost 计费(不截断, 否则大包
//     会少收费, 使长期速率高于配置值), 不报错。
//////////////////////////////////////////////////////////////////////////////////////

`ifndef TOKEN_BUCKET_LITE__SV
`define TOKEN_BUCKET_LITE__SV

class token_bucket_lite;

    // 令牌产生速率(token/sec)
    protected real rate;
    // 桶深(token), 决定允许的最大突发量
    protected real bucket;
    // 理论到达时间(ns), 唯一状态
    protected real tat_ns;
    // 串行化, 保证多 sequence 共享同一个桶时总流量受限
    protected semaphore sem;

    // init_tokens 为负表示初始装满
    function new(real rate_tokens_per_sec, real bucket_size, real init_tokens = -1.0);
        real init_tok;

        if (rate_tokens_per_sec <= 0.0)
            `uvm_fatal("TBL_CFG", $sformatf("illegal rate=%.3f, must be > 0", rate_tokens_per_sec))
        if (bucket_size <= 0.0)
            `uvm_fatal("TBL_CFG", $sformatf("illegal bucket_size=%.3f, must be > 0", bucket_size))

        rate   = rate_tokens_per_sec;
        bucket = bucket_size;
        sem    = new(1);

        init_tok = (init_tokens < 0.0) ? bucket_size : init_tokens;
        if (init_tok > bucket_size) init_tok = bucket_size;

        // 由初始令牌数反推 tat: tokens = B - (tat - now)*R
        tat_ns = real'($realtime) + tok2ns(bucket - init_tok);
    endfunction

    // 令牌数换算为时间(ns)
    protected function real tok2ns(real tok);
        return (tok / rate) * 1e9;
    endfunction

    // 阻塞式取令牌
    // 时隙在锁内原子预约, 等待在锁外进行: 既保证总速率受限, 又避免一条流
    // 等待时锁住整个桶(队头阻塞)。
    task consume(real cost);
        real t_ns;
        real earliest_ns;
        real start_ns;

        // 负 cost 会把 tat 往回拨, 破坏单调性
        if (cost <= 0.0) return;

        sem.get(1);
        t_ns = real'($realtime);
        // tokens >= cost  <=>  t >= tat - (B - cost)/R
        earliest_ns = tat_ns - tok2ns(bucket - cost);
        start_ns    = (earliest_ns > t_ns) ? earliest_ns : t_ns;
        // 预约时隙: tat = max(放行时刻, tat) + cost/R
        // 内层 max 对应"桶满即溢出": 长时间空闲后 tat 已在过去, 不抬到
        // 放行时刻就等于让桶攒出超过 B 的额度。
        tat_ns      = ((start_ns > tat_ns) ? start_ns : tat_ns) + tok2ns(cost);
        sem.put(1);

        if (start_ns > t_ns) #((start_ns - t_ns) * 1ns);
    endtask

endclass: token_bucket_lite

`endif // TOKEN_BUCKET_LITE__SV
