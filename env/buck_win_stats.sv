//////////////////////////////////////////////////////////////////////////////////////
//     dem_buck demo: 滑动窗口流量统计
//
//     完全独立的统计组件:
//       - 只订阅 buck_transaction, 按 len 累计字节, 不读任何整形参数
//       - 不做判定, 不算上界, 不报 error
//       - 窗口分段(个数) 与各段宽度(时间) 全部在初始化阶段给定
//
//     monitor 的 measured_Bps() 只给"首包到末包"这一个固定窗口的平均值, 会被
//     开场突发污染, 且无法回答"某个长度 W 的窗口里最多走了多少字节"。本组件对
//     多个窗口宽度同时做滑窗统计, 给出每个宽度下的峰值字节数与峰值速率。
//     平均速率不在此处重复计算, 需要时看 monitor。
//
//     窗口的两种初始化方式(build_phase 读 config_db, 二者取一):
//       1. 自动分段 "win_max_us" / "win_num": 给最大窗口宽度与分段个数,
//          组件把它等分为 N 档: W_i = win_max_us * i / win_num  (i = 1..N)
//          最窄一档即 win_max_us/win_num, 最宽一档就是 win_max_us
//            uvm_config_db #(real)::set(this, "env.win_stats", "win_max_us", 1000.0);
//            uvm_config_db #(int) ::set(this, "env.win_stats", "win_num",    8);
//          默认 win_max_us = 1000us, win_num = 8, 即 125/250/.../1000 us
//       2. 显式列表 "win_us": 直接给各段宽度(us), 元素个数即分段数;
//          给了 win_us 则上面两项被忽略
//            uvm_config_db #(buck_win_us_t)::set(this, "env.win_stats",
//                                                "win_us", '{20.0, 100.0, 500.0});
//     也可拿到句柄后在 end_of_elaboration_phase 直接改 win_us, 窗口到
//     start_of_simulation_phase 才真正建立。
//
//     算法: 窗口取半开区间 (t-W, t]。由于字节只在离散时刻到达, 任意 W 宽窗口
//     的最大值必然在某个到达时刻取到右端点, 所以只需在每次到达时弹出左端滑出
//     的事件并更新 running sum, 即 O(1) 均摊。
//
//     注意: 时间戳取包的末 beat(monitor 的 ap.write 时刻), 即一个包的字节全部
//     记在它传输完成的瞬间。因此有两类行没有参考意义, 默认被 hide_noise 裁掉:
//       - depth <= 1: 窗口装不下两个包, 峰值速率 = len/W, 反映总线粒度
//       - W > 采样跨度: 窗口比 first..last 还宽, 峰值恒等于总字节数, 不含窗口信息
//
//     反推整形参数: 理论上界 peak(W) <= R*W + B 是一条直线, 对有效点做最小二乘
//     拟合即可从总线实测数据反推出速率 R(斜率) 与桶深 B(截距)。单点无法分离二
//     者(一个方程两个未知数), 必须多档 W 联立。结果打印到 report 并写入文件:
//       uvm_config_db #(string)::set(this, "env.win_stats", "fit_file", "win_fit.txt");
//     置空字符串则不写文件。
//
//     异常自动检测: 对残差做离群判定, 某点高出拟合直线 chk_sigma 倍标准差即报出。
//     只报正偏差(超发), 欠发不违反整形契约。默认 chk_sigma=3.0 报 warning:
//       uvm_config_db #(real)::set(this, "env.win_stats", "chk_sigma",    3.0);
//       uvm_config_db #(bit) ::set(this, "env.win_stats", "chk_as_error", 1);
//     chk_sigma=0 关闭检测。注意此法查的是曲线形状是否自洽, 若 DUT 整体漏速
//     (所有点仍共线, 只是斜率偏大), 残差全为 0, 需另行拿 fit_R/fit_B 比对契约值。
//
//     契约比对(可选, 补上面的盲区): 给出期望的 R/B, 与拟合值比相对误差。
//     不给(保持 <= 0)则不比对, 组件维持零耦合:
//       uvm_config_db #(real)::set(this, "env.win_stats", "exp_R",   10.0);
//       uvm_config_db #(real)::set(this, "env.win_stats", "exp_B",   1024.0);
//       uvm_config_db #(real)::set(this, "env.win_stats", "exp_tol", 0.05);
//     两项可单独给。严重级别同样由 chk_as_error 控制。
//
//     注: 曾经还做过一道"凹性检查"(查相邻档斜率是否单调不增), 已移除。理由是
//     peak(W) 对离散包流只保证次可加, 并不保证凹 —— 窗口边界扫过一个包时 peak
//     会整包跳一级, 局部斜率必然在 0 与"整包/步长"之间抖, 噪声底就是一个包长。
//     门限小于包长必误报, 大于包长则真实偏差也一并放过, 两头不可兼得。单档翘起
//     这类形变交给 exp_R/exp_B 契约比对去抓。
//////////////////////////////////////////////////////////////////////////////////////

`ifndef BUCK_WIN_STATS__SV
`define BUCK_WIN_STATS__SV

// config_db 传窗口列表用; queue 必须经 typedef 才能作为 config_db 的类型参数
typedef real buck_win_us_t[$];

// 单个固定宽度的滑动窗口
class sliding_window;

    // 窗口宽度(ns)
    protected real width_ns;
    // 窗口内事件: 时刻与字节数
    protected real t_q[$];
    protected real b_q[$];
    // 窗口内合计字节
    protected real sum;

    // 峰值及其右端点
    real         peak_bytes;
    real         peak_end_ns;
    // 取到峰值时窗口内的包数, 用于判断该行是否只覆盖了单个包
    int unsigned peak_depth;
    // 窗口内包数的历史最大值
    int unsigned max_depth;

    function new(real w_ns);
        width_ns    = w_ns;
        sum         = 0.0;
        peak_bytes  = 0.0;
        peak_end_ns = 0.0;
        peak_depth  = 0;
        max_depth   = 0;
    endfunction

    function real width();
        return width_ns;
    endfunction

    // 记入一个在 t_ns 完成的包, 返回窗口 (t_ns-W, t_ns] 内的字节合计
    // 要求 t_ns 单调不减(monitor 按时间顺序 write, 天然满足)
    function real add(real t_ns, real nbytes);
        real lo;

        lo = t_ns - width_ns;

        t_q.push_back(t_ns);
        b_q.push_back(nbytes);
        sum += nbytes;

        // 弹出滑出左边界的事件; 半开区间故用 <=
        while (t_q.size() > 0 && t_q[0] <= lo) begin
            sum -= b_q[0];
            void'(t_q.pop_front());
            void'(b_q.pop_front());
        end

        if (sum > peak_bytes) begin
            peak_bytes  = sum;
            peak_end_ns = t_ns;
            peak_depth  = t_q.size();
        end
        if (t_q.size() > max_depth)
            max_depth = t_q.size();

        return sum;
    endfunction

    // 当前窗口内的字节合计, 即最近一次 add() 之后的 running sum
    function real cur_bytes();
        return sum;
    endfunction

    // 峰值速率(byte/sec)
    function real peak_Bps();
        if (width_ns <= 0.0) return 0.0;
        return peak_bytes / (width_ns / 1e9);
    endfunction

endclass: sliding_window


class buck_win_stats extends uvm_subscriber #(buck_transaction);

    // 各段窗口宽度(us)。元素个数 = 分段数。非空则直接采用
    real win_us[$];

    // win_us 为空时自动分段: 把 win_max_us 等分为 win_num 档
    real win_max_us;
    int  win_num;

    // 1=裁掉没有参考意义的行(depth<=1 以及宽于采样跨度的行)
    bit hide_noise;

    // 拟合结果落盘的文件名, 置空则不写文件
    string fit_file;

    // 残差离群检测: 残差 > chk_sigma 倍标准差即判为异常
    // 0 = 关闭检测; 典型取 3.0
    real chk_sigma;
    // 1 = 异常报 uvm_error(判用例失败), 0 = 只报 uvm_warning
    bit chk_as_error;

    // 契约比对(可选): 期望的速率与桶深, <= 0 表示不比对该项
    // 用于抓残差查不出的"整体偏移"(所有点仍共线, 只是斜率/截距偏了)
    // 判定方向不同: exp_R 是要被打准的目标值, 双侧判(偏高偏低都报);
    //               exp_B 是契约给的上界, 单侧判(只有拟合值超出才报)
    real exp_R;         // byte/us
    real exp_B;         // byte
    // 相对容差, 0.05 即允许 5% 偏差
    real exp_tol;

    protected sliding_window win[$];

    // 最小二乘拟合 peak(W) = R*W + B 的结果
    // fit_R: byte/us   fit_B: byte   fit_n: 参与拟合的点数
    real fit_R;
    real fit_B;
    int  fit_n;

    // 全局计数, 用于与 monitor 交叉核对
    protected int unsigned  pkt_cnt;
    protected real          total_bytes;
    protected real          first_ns;
    protected real          last_ns;

    `uvm_component_utils(buck_win_stats)

    function new(string name = "buck_win_stats", uvm_component parent = null);
        super.new(name, parent);
        win_max_us  = 1000.0;
        win_num     = 8;        // 125 / 250 / ... / 1000 us
        hide_noise  = 1;
        fit_file    = "win_fit.txt";
        chk_sigma    = 3.0;
        chk_as_error = 0;
        exp_R        = 0.0;     // <= 0 即不比对
        exp_B        = 0.0;
        exp_tol      = 0.05;
        fit_R       = 0.0;
        fit_B       = 0.0;
        fit_n       = 0;
        pkt_cnt     = 0;
        total_bytes = 0.0;
        first_ns    = 0.0;
        last_ns     = 0.0;
    endfunction

    // 初始化: 窗口分段与各段时间在此确定
    function void build_phase(uvm_phase phase);
        buck_win_us_t q;
        int           i_num;
        real          r_val;
        super.build_phase(phase);

        void'(uvm_config_db #(bit)::get(this, "", "hide_noise", hide_noise));
        void'(uvm_config_db #(string)::get(this, "", "fit_file", fit_file));
        void'(uvm_config_db #(real)::get(this, "", "chk_sigma", chk_sigma));
        void'(uvm_config_db #(bit)::get(this, "", "chk_as_error", chk_as_error));
        void'(uvm_config_db #(real)::get(this, "", "exp_R",   exp_R));
        void'(uvm_config_db #(real)::get(this, "", "exp_B",   exp_B));
        void'(uvm_config_db #(real)::get(this, "", "exp_tol", exp_tol));

        if (uvm_config_db #(buck_win_us_t)::get(this, "", "win_us", q)) begin
            win_us = q;
            return;     // 显式列表优先, 自动分段参数不再读
        end

        if (uvm_config_db #(real)::get(this, "", "win_max_us", r_val))
            win_max_us = r_val;
        if (uvm_config_db #(int)::get(this, "", "win_num", i_num))
            win_num = i_num;
    endfunction

    // 窗口在此建立, 故 win_us 最晚可在 end_of_elaboration_phase 改写
    function void start_of_simulation_phase(uvm_phase phase);
        sliding_window w;
        real           wd;
        super.start_of_simulation_phase(phase);

        if (win_us.size() == 0)
            split_window();

        foreach (win_us[i]) begin
            wd = win_us[i];
            if (wd > 0.0) begin
                w = new(wd * 1e3);
                win.push_back(w);
            end
            else
                `uvm_warning("BUCK_WIN", $sformatf("win_us[%0d] = %.3f <= 0, skipped", i, wd))
        end

        if (win.size() == 0)
            `uvm_fatal("BUCK_WIN", "no valid window configured")

        `uvm_info("BUCK_WIN", $sformatf("%0d window(s) built", win.size()), UVM_HIGH)
    endfunction

    // 把 win_max_us 等分为 win_num 档: W_i = win_max_us * i / win_num
    protected function void split_window();
        if (win_num <= 0)
            `uvm_fatal("BUCK_WIN", $sformatf("win_num = %0d, must be > 0", win_num))
        if (win_max_us <= 0.0)
            `uvm_fatal("BUCK_WIN", $sformatf("win_max_us = %.3f, must be > 0", win_max_us))

        for (int i = 1; i <= win_num; i++)
            win_us.push_back(win_max_us * real'(i) / real'(win_num));
    endfunction

    // monitor 每聚出一个完整包就调一次
    function void write(buck_transaction t);
        real nbytes;
        real now_ns;

        if (t == null) return;

        nbytes = real'(t.len);
        now_ns = real'($realtime);

        if (pkt_cnt == 0) first_ns = now_ns;
        last_ns = now_ns;

        pkt_cnt++;
        total_bytes += nbytes;

        foreach (win[i])
            void'(win[i].add(now_ns, nbytes));
    endfunction

    // 对外: 第 i 段的峰值速率(byte/sec)
    function real peak_Bps(int unsigned idx);
        if (idx >= win.size()) return 0.0;
        return win[idx].peak_Bps();
    endfunction

    // 对外: 第 i 段的峰值字节数
    function real peak_bytes(int unsigned idx);
        if (idx >= win.size()) return 0.0;
        return win[idx].peak_bytes;
    endfunction

    function int unsigned num_windows();
        return win.size();
    endfunction

    // 对外: 第 i 段当前窗口内的字节合计(running sum)
    function real cur_bytes(int unsigned idx);
        if (idx >= win.size()) return 0.0;
        return win[idx].cur_bytes();
    endfunction

    // 全局平均速率(byte/sec), 窗口取首包到末包的跨度
    // 与滑窗峰值对照看: peak/avg 的比值即突发程度, 比值趋近 1 说明流量平坦
    function real avg_Bps();
        if (last_ns <= first_ns) return 0.0;
        return total_bytes / ((last_ns - first_ns) / 1e9);
    endfunction

    // 全局累计字节与包数
    function real tot_bytes();
        return total_bytes;
    endfunction

    function int unsigned tot_pkts();
        return pkt_cnt;
    endfunction

    // 最小二乘拟合 peak(W) = R*W + B
    //   W 取 us, peak 取 byte, 故 R 的单位是 byte/us, B 的单位是 byte
    //   只采用有参考意义的点: peak_depth > 1 且 W <= 采样跨度
    //   理论上界 peak(W) <= R*W + B 是直线, 斜率给出速率, 截距给出桶深
    protected function void fit_line();
        real span_ns;
        real w_us, y;
        real sx, sy, sxx, sxy;
        real n, den;

        fit_R = 0.0;
        fit_B = 0.0;
        fit_n = 0;

        span_ns = last_ns - first_ns;
        sx = 0.0; sy = 0.0; sxx = 0.0; sxy = 0.0;

        foreach (win[i]) begin
            if (win[i].peak_depth <= 1)      continue;
            if (win[i].width() > span_ns)    continue;

            w_us = win[i].width() / 1e3;
            y    = win[i].peak_bytes;

            sx  += w_us;
            sy  += y;
            sxx += w_us * w_us;
            sxy += w_us * y;
            fit_n++;
        end

        // 少于两个点无法分离斜率与截距
        if (fit_n < 2) begin
            fit_n = 0;
            return;
        end

        n   = real'(fit_n);
        den = n * sxx - sx * sx;
        if (den == 0.0) begin   // 所有 W 相同
            fit_n = 0;
            return;
        end

        fit_R = (n * sxy - sx * sy) / den;
        fit_B = (sy - fit_R * sx) / n;
    endfunction

    // 把拟合结果与数据点写入文件
    protected function void dump_fit();
        int  fd;
        real span_ns;
        real w_us, y, pred;

        if (fit_file.len() == 0) return;

        fd = $fopen(fit_file, "w");
        if (fd == 0) begin
            `uvm_warning("BUCK_WIN", $sformatf("cannot open %s for write", fit_file))
            return;
        end

        span_ns = last_ns - first_ns;

        $fdisplay(fd, "# sliding window traffic profile / least-squares fit");
        $fdisplay(fd, "# model : peak(W) = R*W + B    [W in us, peak in byte]");
        $fdisplay(fd, "packets      = %0d", pkt_cnt);
        $fdisplay(fd, "total_byte   = %.0f", total_bytes);
        $fdisplay(fd, "span_us      = %.3f", span_ns / 1e3);
        $fdisplay(fd, "avg_byte_us  = %.4f", avg_Bps() / 1e6);

        if (fit_n < 2) begin
            $fdisplay(fd, "fit_points   = %0d (too few, fit skipped)", fit_n);
            $fclose(fd);
            `uvm_info("BUCK_WIN", $sformatf("fit result written to %s (no fit)", fit_file), UVM_LOW)
            return;
        end

        $fdisplay(fd, "fit_points   = %0d", fit_n);
        $fdisplay(fd, "fit_R        = %.4f  byte/us   # slope    -> shaper rate",  fit_R);
        $fdisplay(fd, "fit_B        = %.1f  byte      # intercept-> bucket depth", fit_B);
        $fdisplay(fd, "");
        $fdisplay(fd, "# %10s %12s %12s %12s", "W(us)", "peak", "fitted", "residual");

        foreach (win[i]) begin
            if (win[i].peak_depth <= 1)      continue;
            if (win[i].width() > span_ns)    continue;

            w_us = win[i].width() / 1e3;
            y    = win[i].peak_bytes;
            pred = fit_R * w_us + fit_B;
            $fdisplay(fd, "  %10.3f %12.0f %12.1f %12.1f", w_us, y, pred, y - pred);
        end

        $fclose(fd);
        `uvm_info("BUCK_WIN", $sformatf("fit result written to %s", fit_file), UVM_LOW)
    endfunction

    // 残差离群检测: 把实测 peak 与拟合直线的偏差做标准化, 超过 chk_sigma 倍
    // 标准差即判为异常。不依赖任何外部参数, 查的是曲线自身的形状是否自洽。
    //
    // 局限: 若 DUT 整体漏速(例如实际 R 是契约的两倍), 所有点仍严格共线,
    //       残差全为 0, 此法查不出来。那种情况需要拿 fit_R/fit_B 与契约值比对。
    protected function void check_outlier();
        real span_ns;
        real w_us, y, pred, resi;
        real ss, sigma;
        real q_w[$], q_resi[$];
        int  n_bad;
        string s;

        if (chk_sigma <= 0.0) return;   // 检测关闭
        if (fit_n < 3)        return;   // 两点必然共线, 残差恒为 0, 无从判离群

        span_ns = last_ns - first_ns;
        ss      = 0.0;

        foreach (win[i]) begin
            if (win[i].peak_depth <= 1)   continue;
            if (win[i].width() > span_ns) continue;

            w_us = win[i].width() / 1e3;
            y    = win[i].peak_bytes;
            pred = fit_R * w_us + fit_B;
            resi = y - pred;

            q_w.push_back(w_us);
            q_resi.push_back(resi);
            ss += resi * resi;
        end

        // 拟合用掉 2 个自由度(斜率与截距), 故除以 n-2
        sigma = $sqrt(ss / real'(fit_n - 2));

        // 所有点完全共线: 没有离散度可言, 不做判定
        if (sigma <= 0.0) return;

        n_bad = 0;
        s     = "";

        foreach (q_resi[i]) begin
            // 只报正偏差: 实测高于拟合直线才是超发, 低于是欠发(不违反整形契约)
            if (q_resi[i] > chk_sigma * sigma) begin
                n_bad++;
                s = {s, $sformatf("\n    W = %.3f us: peak exceeds fit by %.1f byte (%.2f sigma)",
                                  q_w[i], q_resi[i], q_resi[i] / sigma)};
            end
        end

        if (n_bad == 0) begin
            `uvm_info("BUCK_WIN",
                      $sformatf("outlier check passed: %0d pts, sigma = %.1f byte", fit_n, sig ma),
                      UVM_LOW)
            return;
        end

        s = {$sformatf("sliding window outlier: %0d of %0d point(s) above fit by > %.1f sigma (sigma = %.1f byte)",
                       n_bad, fit_n, chk_sigma, sigma), s,
             "\n    these windows carried more bytes than the shaper profile allows;",
             "\n    use the peak@ column of the same row to locate it in the waveform"};

        if (chk_as_error)
            `uvm_error("BUCK_WIN", s)
        else
            `uvm_warning("BUCK_WIN", s)
    endfunction

    // 契约比对(可选): 拿拟合出的 R/B 与期望值比
    // 与 check_outlier() 互补 —— 后者查曲线形状是否自洽(抓局部翘起),
    // 本函数查曲线位置是否正确(抓整体偏移, 那种情况下残差全为 0)
    protected function void check_contract();
        real err;
        string s;
        string sign;
        int    n_bad;

        if (exp_R <= 0.0 && exp_B <= 0.0) return;   // 两项都没给, 不比对
        if (fit_n < 2) begin
            `uvm_warning("BUCK_WIN", "contract check skipped: fit unavailable")
            return;
        end

        n_bad = 0;
        s     = "";

        // VCS 不认 %+ 这个符号标志, 正号自己拼
        if (exp_R > 0.0) begin
            err = (fit_R - exp_R) / exp_R;
            if (err > exp_tol || err < -exp_tol) begin
                n_bad++;
                sign = (err >= 0.0) ? "+" : "";
                s = {s, $sformatf("\n    R: fit = %.4f, expect = %.4f byte/us, err = %s%.2f%% (tol %.2f%%)",
                                  fit_R, exp_R, sign, err * 100.0, exp_tol * 100.0)};
            end
        end

        // B 是包络的上界参数, 判定是单侧的:
        //   fit_B 偏小是合法的 —— 说明突发信用没被用满(空桶起步/请求不够密),
        //   曲线只是贴在上界下方, 并未违约;
        //   fit_B 超出 exp_B 才是真问题 —— 实际突发比桶深还大, 整形器漏了。
        // 这与 check_outlier() 只判正残差同源: 两道检查都只管"不许更快"。
        if (exp_B > 0.0) begin
            err = (fit_B - exp_B) / exp_B;
            if (err > exp_tol) begin
                n_bad++;
                s = {s, $sformatf("\n    B: fit = %.1f, expect <= %.1f byte, over by +%.2f%% (tol %.2f%%)",
                                  fit_B, exp_B, err * 100.0, exp_tol * 100.0)};
            end
        end

        if (n_bad == 0) begin
            `uvm_info("BUCK_WIN",
                      $sformatf("contract check passed: R = %.4f byte/us, B = %.1f byte", fit_R, fit_B),
                      UVM_LOW)
            return;
        end

        s = {$sformatf("shaper profile deviates from contract (%0d item(s)):", n_bad), s,
             "\n    the fitted line is in the wrong place -- check the rate/depth",
             "\n    actually programmed into the DUT against the expected values"};

        if (chk_as_error)
            `uvm_error("BUCK_WIN", s)
        else
            `uvm_warning("BUCK_WIN", s)

    endfunction

    function void report_phase(uvm_phase phase);
        string s;
        real   w_ns;
        real   span_ns;
        int    n_thin;      // depth<=1 被裁的行数
        int    n_wide;      // 宽于采样跨度被裁的行数
        super.report_phase(phase);

        if (pkt_cnt == 0) begin
            `uvm_info("BUCK_WIN", "no sample collected", UVM_LOW)
            return;
        end

        span_ns = last_ns - first_ns;
        n_thin  = 0;
        n_wide  = 0;

        fit_line();

        s = $sformatf("\n---------------- sliding window traffic profile ----------------\n");
        s = {s, $sformatf("  packets   = %0d,  total = %.0f byte\n", pkt_cnt, total_bytes)};
        s = {s, $sformatf("  span      = %.3f us (first..last pkt)\n", span_ns / 1e3)};
        s = {s, $sformatf("  avg       = %.4f byte/us (global)\n", avg_Bps() / 1e6)};
        s = {s, $sformatf("  %11s %12s %14s %12s %7s\n",
                          "W(us)", "peak byte", "peak byte/us", "peak@(us)", "depth")};

        foreach (win[i]) begin
            w_ns = win[i].width();

            if (hide_noise) begin
                // 窗口装不下两个包: 峰值速率只反映总线粒度
                if (win[i].peak_depth <= 1) begin
                    n_thin++;
                    continue;
                end
                // 窗口宽于采样跨度: 峰值必然等于总字节数, 与 avg 重复
                if (w_ns > span_ns) begin
                    n_wide++;
                    continue;
                end
            end

            s = {s, $sformatf("  %11.3f %12.0f %14.4f %12.3f %7d\n",
                              w_ns / 1e3,
                              win[i].peak_bytes,
                              win[i].peak_Bps() / 1e6,
                              win[i].peak_end_ns / 1e3,
                              win[i].peak_depth)};
        end

        if (n_thin > 0 || n_wide > 0)
            s = {s, $sformatf("  hidden: %0d row(s) too narrow (single pkt), %0d row(s) wider than span\n",
                              n_thin, n_wide)};

        // 拟合 peak(W) = R*W + B: 斜率即速率, 截距即桶深
        if (fit_n >= 2)
            s = {s, $sformatf("  fit(%0d pts): R = %.4f byte/us,  B = %.1f byte\n",
                              fit_n, fit_R, fit_B)};
        else
            s = {s, "  fit: skipped (less than 2 valid points)\n"};

        s = {s, "---------------------------------------------------------------"};

        `uvm_info("BUCK_WIN", s, UVM_LOW)

        dump_fit();
        check_outlier();
        check_contract();
    endfunction

endclass: buck_win_stats

`endif // BUCK_WIN_STATS__SV
