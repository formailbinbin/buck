//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: 令牌桶流控核心
//
//     - token_bucket_cfg : 速率/桶深配置
//     - token_bucket     : 基于虚拟时间(GCRA)的令牌桶, 不起后台线程
//
//     实现说明:
//     不维护"当前令牌数", 而是维护 tat(理论到达时间)。二者严格等价:
//         tokens(t) = bucket_size - (tat - t) * rate
//     放行条件 tokens >= cost 等价于 t >= tat - (bucket_size - cost)/rate,
//     因此所需等待时间可一次性闭式算出, 无需循环逼近, 也不会有浮点累加漂移。
//
//     速率单位由调用方自定: 若 item_cost 返回包长(byte), 则 rate 为 byte/sec;
//     若 item_cost 返回 1, 则 rate 为 packet/sec。
//////////////////////////////////////////////////////////////////////////////////////

`ifndef TOKEN_BUCKET__SV
`define TOKEN_BUCKET__SV

class token_bucket_cfg extends uvm_object;

    // 令牌产生速率(token/sec)
    real rate_tokens_per_sec = 1_000_000.0;
    // 桶深(token), 决定允许的最大突发量
    real bucket_size         = 1024.0;
    // 初始令牌数, 负值表示初始装满
    real init_tokens         = -1.0;
    // 单包开销超过桶深时: 1=放行(按实际开销计费, 自动延长等待), 0=报 fatal
    bit  allow_oversize      = 1;

    `uvm_object_utils_begin(token_bucket_cfg)
        `uvm_field_real(rate_tokens_per_sec, UVM_ALL_ON)
        `uvm_field_real(bucket_size,         UVM_ALL_ON)
        `uvm_field_real(init_tokens,         UVM_ALL_ON)
        `uvm_field_int (allow_oversize,      UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "token_bucket_cfg");
        super.new(name);
    endfunction

endclass: token_bucket_cfg


class token_bucket extends uvm_object;

    token_bucket_cfg cfg;

    // 理论到达时间(ns), 虚拟时间刻度。tokens = bucket_size - (tat_ns - now)*rate
    protected real tat_ns;
    // 串行化, 保证多 sequence 共享同一个桶时总流量受限
    protected semaphore sem;

    // 统计
    int unsigned grant_cnt;
    real         total_cost;
    realtime     first_grant;
    realtime     last_grant;
    realtime     total_stall;

    // 稳态统计: 开场突发期(桶里有存货, 不需要等待)不计入
    // 第一次发生 stall 说明桶已被抽干, 此后进入速率受限的稳态
    protected bit      steady_valid;
    protected realtime steady_start_time;
    protected real     steady_start_cost;
    protected int unsigned steady_start_cnt;

    // 符合性: 任意窗口内放行量应满足 cost <= R*T + B
    // 令 f(t) = total_cost(t) - R*t, 则任意窗口的放行量超出部分为 f(t2) - f(t1),
    // 其最大值即 f(t) - min(f), 故需跟踪 f 的 running 最小值, 否则会漏掉
    // "中途空闲把 f 压低、随后再突发" 的情况。
    real max_excess;
    protected real f_min;

    `uvm_object_utils(token_bucket)

    function new(string name = "token_bucket");
        super.new(name);
        sem = new(1);
    endfunction

    // 必须在使用前调用
    function void configure(token_bucket_cfg c);
        real init_tok;

        if (c == null)
            `uvm_fatal("TB_CFG", "token_bucket_cfg is null")
        if (c.rate_tokens_per_sec <= 0.0)
            `uvm_fatal("TB_CFG", $sformatf("illegal rate=%.3f, must be > 0", c.rate_tokens_per_sec))
        if (c.bucket_size <= 0.0)
            `uvm_fatal("TB_CFG", $sformatf("illegal bucket_size=%.3f, must be > 0", c.bucket_size))

        cfg      = c;
        init_tok = (c.init_tokens < 0.0) ? c.bucket_size : c.init_tokens;
        if (init_tok > c.bucket_size) init_tok = c.bucket_size;

        // 由初始令牌数反推 tat: tokens = B - (tat - now)*R
        tat_ns = real'($realtime) + tok2ns(cfg.bucket_size - init_tok);

        grant_cnt    = 0;
        total_cost   = 0.0;
        total_stall  = 0;
        steady_valid = 0;
        max_excess   = 0.0;
        f_min        = 0.0;

        `uvm_info("TB_CFG", $sformatf("token_bucket configured: rate=%.3e token/s, bucket=%.1f, init=%.1f",
                  cfg.rate_tokens_per_sec, cfg.bucket_size, init_tok), UVM_LOW)
    endfunction

    // 令牌数换算为时间(ns)
    protected function real tok2ns(real tok);
        return (tok / cfg.rate_tokens_per_sec) * 1e9;
    endfunction

    // 校验开销。注意: 超桶深的包按"实际开销"计费并自动延长等待,
    // 不做截断 —— 截断会导致大包少收费, 使长期速率高于配置值。
    protected function real effective_cost(real cost);
        if (cost <= 0.0) return 0.0;
        if (cost > cfg.bucket_size) begin
            if (cfg.allow_oversize)
                `uvm_warning("TB_OVERSIZE", $sformatf(
                             "cost %.1f > bucket_size %.1f, admitted with extended delay",
                             cost, cfg.bucket_size))
            else
                `uvm_fatal("TB_OVERSIZE", $sformatf("cost %.1f exceeds bucket_size %.1f",
                           cost, cfg.bucket_size))
        end
        return cost;
    endfunction

    // 阻塞式取令牌
    // 时隙在锁内原子预约, 等待在锁外进行: 既保证总速率受限与 FIFO 公平,
    // 又避免一条流等待时锁住整个桶(队头阻塞)。
    task consume(real cost);
        real     need;
        real     t_ns;
        real     earliest_ns;
        real     start_ns;
        real     delay_ns;
        realtime t_enter;
        bit      stalled;

        t_enter = $realtime;
        need    = effective_cost(cost);

        sem.get(1);
        t_ns = real'($realtime);
        // tokens >= need  <=>  t >= tat - (B - need)/R
        earliest_ns = tat_ns - tok2ns(cfg.bucket_size - need);
        start_ns    = (earliest_ns > t_ns) ? earliest_ns : t_ns;
        // 预约时隙: tat = max(放行时刻, tat) + need/R
        tat_ns      = ((start_ns > tat_ns) ? start_ns : tat_ns) + tok2ns(need);
        sem.put(1);

        delay_ns = start_ns - t_ns;
        stalled  = (delay_ns > 0.0);
        if (stalled) #(delay_ns * 1ns);

        // 以下均为非阻塞运算, 天然原子, 无需持锁
        if (grant_cnt == 0) begin
            first_grant = $realtime;
            last_grant  = $realtime;
        end
        if ($realtime > last_grant) last_grant = $realtime;
        grant_cnt++;
        total_stall += ($realtime - t_enter);

        account(need);

        // 首次 stall 表示突发信用已耗尽, 从这一刻起算稳态窗口
        if (stalled && !steady_valid) begin
            steady_valid      = 1;
            steady_start_time = $realtime;
            steady_start_cost = total_cost;
            steady_start_cnt  = grant_cnt;
        end

        `uvm_info("TB_GRANT", $sformatf("granted cost=%.1f, tokens left=%.1f @%0t",
                  need, current_tokens(), $realtime), UVM_DEBUG)
    endtask

    // 累加开销并更新符合性统计(跟踪 f 的 running 最小值)
    protected function void account(real add_cost);
        real span_s;
        real f_before;
        real f_after;

        span_s   = (last_grant - first_grant) / 1e9;
        f_before = total_cost - span_s * cfg.rate_tokens_per_sec;
        if (f_before < f_min) f_min = f_before;

        total_cost += add_cost;

        f_after = total_cost - span_s * cfg.rate_tokens_per_sec;
        if ((f_after - f_min) > max_excess) max_excess = f_after - f_min;
    endfunction

    // 非阻塞式取令牌: 令牌不足立即返回 0
    function bit try_consume(real cost);
        real need;
        real t_ns;
        real earliest_ns;

        need = effective_cost(cost);
        t_ns = real'($realtime);

        earliest_ns = tat_ns - tok2ns(cfg.bucket_size - need);
        if (earliest_ns > t_ns) return 0;

        tat_ns = ((t_ns > tat_ns) ? t_ns : tat_ns) + tok2ns(need);

        if (grant_cnt == 0) begin
            first_grant = $realtime;
            last_grant  = $realtime;
        end
        if ($realtime > last_grant) last_grant = $realtime;
        grant_cnt++;
        account(need);
        return 1;
    endfunction

    // 当前可用令牌数, 可能为负(超桶深的包借支了未来额度)
    function real current_tokens();
        real tok;
        tok = cfg.bucket_size - (tat_ns - real'($realtime)) * cfg.rate_tokens_per_sec / 1e9;
        return (tok > cfg.bucket_size) ? cfg.bucket_size : tok;
    endfunction

    // 实测速率(token/sec), 含开场突发。窗口 T 较短时会偏高约 B/(R*T)
    function real measured_rate();
        real span_s;
        if (grant_cnt < 2) return 0.0;
        span_s = (last_grant - first_grant) / 1e9;
        if (span_s <= 0.0) return 0.0;
        return total_cost / span_s;
    endfunction

    // 稳态速率(token/sec): 排除开场突发期, 应收敛到配置速率
    function real steady_rate();
        real span_s;
        if (!steady_valid) return 0.0;
        if ((grant_cnt - steady_start_cnt) < 2) return 0.0;
        span_s = (last_grant - steady_start_time) / 1e9;
        if (span_s <= 0.0) return 0.0;
        return (total_cost - steady_start_cost) / span_s;
    endfunction

    function bit steady_available();
        return steady_valid && ((grant_cnt - steady_start_cnt) >= 2);
    endfunction

    // 符合性: 实际用掉的突发信用不得超过桶深(留 1% 容差吸收浮点误差)
    function bit is_conformant();
        return (max_excess <= cfg.bucket_size * 1.01);
    endfunction

    function void print_stats(string tag = "");
        `uvm_info("TB_STATS", $sformatf(
            "\n---------------- token_bucket stats %s ----------------\n  cfg rate     = %.3e token/s\n  bucket_size  = %.1f\n  grant_cnt    = %0d\n  total_cost   = %.0f token\n  window       = %.3f us\n  measured     = %.3e token/s\n  rate error   = %.2f pct\n  steady       = %.3e token/s\n  steady error = %.2f pct\n  burst used   = %.1f / %.1f token\n  conformant   = %s\n  total_stall  = %.3f us\n--------------------------------------------------------",
            tag, cfg.rate_tokens_per_sec, cfg.bucket_size, grant_cnt, total_cost,
            (last_grant - first_grant) / 1000.0, measured_rate(),
            (measured_rate() / cfg.rate_tokens_per_sec - 1.0) * 100.0,
            steady_rate(),
            steady_available() ? (steady_rate() / cfg.rate_tokens_per_sec - 1.0) * 100.0 : 0.0,
            max_excess, cfg.bucket_size,
            is_conformant() ? "YES" : "NO",
            total_stall / 1000.0), UVM_LOW)
    endfunction

endclass: token_bucket

`endif // TOKEN_BUCKET__SV
