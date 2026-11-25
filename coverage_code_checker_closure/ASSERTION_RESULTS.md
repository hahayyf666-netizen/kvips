# 断言与过程式 Checker 验收

`assert property` 的尝试、真实成功、失败在 `asserts.txt` 中读取。一次尝试只说明属性被采样。含蕴意的属性需要前提在采样时成立才会得到非空成功。`always_ff` 中的协议检查以 `$error`、源码行与当前 AXI 握手时间为证据。测试使用了 VCS 的 `-exitstatus`，最终 12 个注入的退出码为 2，两项对照为 0。[诊断矩阵](NEGATIVE_TEST_MATRIX.csv)

## 三组 SVA 结果

| 统计区域 | 非空成功 | 失败 |
|---|---:|---:|
| RAM 最新基线 `top.axi` | 27/28 | 0 |
| RAM 最终 `top.axi` | 27/28 | 0 |
| RAM 最终整体，包含库定义 | 28/31 | 0 |
| Checker-only `top.axi` | 24/28 | 1 |

RAM 中取得真实成功的 27 个属性包括 5 个信道 Hold、AW/AR 的 Size、Burst、Len、Transaction Size、WRAP Len、WRAP Addr、4KB 各一对、5 个 `a_kvips_known_*`、两个 Outstanding 限制，以及 `a_kvips_ar_excl_restrictions`。Outstanding 属性在默认最大值 0 时走免限路径。正向 30 项与新增 5 项的 URG 属性失败均为 0。[RAM 原始属性](reports/positive/urg/assertions/asserts.txt)

`axi4_dut_arlock_toggle_test` 的 `ARLOCK=0→1→0` 发生在三个真实 AR 握手上。该测试的 `a_kvips_ar_excl_restrictions` 有 1 次真实成功，后续 RAM 读返回 OKAY，数据经 VCD 及 Scoreboard 检查。[RAM ARLOCK 逐项断言](reports/positive/urg/by_test/axi4_dut_arlock_toggle_test/asserts.txt)

`locked_ok_control` 在独立响应器上发送 0→1→0 的 AWLOCK/ARLOCK，锁定位和 EXOKAY 配对。两项 `a_kvips_aw_excl_restrictions` 与 `a_kvips_ar_excl_restrictions` 均为 26 次尝试、1 次真实成功、0 次失败。`*SIZE=3`、单拍 INCR、地址 `0x100`、总长 8 B 且不跨 4 KB。VIP 原有独占成功与失败测试同时通过。[Checker LOCK 断言](reports/negative/urg/by_test/locked_ok_control/asserts.txt) · [VIP 属性](reports/vip/urg/assertions/asserts.txt)

## AW Hold 对照

`aw_hold_violation` 在 AWREADY=0 时将 AWADDR 从 `0x100` 改成 `0x108`，保持变化后的请求到真实握手。VCD 验证只有这一次受阻载荷变化。VCS 给出 `a_kvips_aw_hold` 一次失败，报告时间为 35 ns 到 45 ns。该单测 URG 显示 16 次尝试、1 次非空成功、1 次失败。复位后完成正常写读对照。首次探针只保留了很短的错误和复位间隔，VCS 报告 0 次失败，延长保持及采样窗口后取得最终结果。[VCS 日志](reports/negative/regression/aw_hold_violation.log) · [独立断言报告](reports/negative/urg/by_test/aw_hold_violation/asserts.txt) · 波形（完整本地归档）

## 过程式诊断

11 个 W/B/R 场景共记录 14 条预期 `$error`。提前 WLAST 同拍两条，W/R Overflow 均在遗漏 LAST 后各多一条。VCD 中实际注入拍与这 14 条诊断时间逐条一致，额外错误为 0。RRESP=EXOKAY 的每个相关测试在日志中记录 `assertions=1 excl=1 known=1`。[逐例签名和分支号](NEGATIVE_TEST_MATRIX.csv)

两个无尝试的断言来自 VCS UVM 库定义，分别位于 `uvm_reg_map::do_read` 和 `do_write`。原始定义分母保留。[排除项审查](EXCLUSION_REVIEW.md)
