# 回归验收证据

| 组别 | 基线 | 最终 | 证据 |
|---|---|---|---|
| 原清单测试 | 17/17 PASS | 17/17 PASS | 两份 `test_results.csv` 的前 17 项 |
| 已有的附加正向用例 | 6/6 PASS | 6/6 PASS | Burst × Size、256 beats、sideband、LOCK、Unaligned INCR E2E、ID Width |
| 本轮新增 DUT 用例 | — | 3/3 PASS | Toggle、Constraint Random、BREADY |
| 独立地址算法 | 42,717 beats、42,765 次比较，错误 0 | 复用基线专项证据 | `METHOD_EVIDENCE/functional_coverage/addr_ref_runner.log` |
| 独立 Early-W | 合法对照 0 报错，注入 0 报错（复现漏报） | 合法对照 0，注入精确 1 个预期报错 | `METHOD_EVIDENCE/negative_tests/early_w_*` |
| 同一夹具 BREADY 对照 | — | 控制/随机均完成 64 B。stall cycles 0 → 154 | `METHOD_EVIDENCE/backpressure/` |

正式正向 VCS 编译通过，26 项均完成规定事务，Checker errors、sideband errors、Scoreboard mismatch、SVA failures、UVM_ERROR 和 UVM_FATAL 均为 0。24 项 SIM_RC=0。WRAP Alignment 和 4KB Boundary 的 SIM_RC=2 分别由一次预期求解拒绝触发，逐日志要求 `CNST-ICE` 和 `CNST-CIF` 各一次，且正确的接受、拒绝和总线响应同时成立。常规未写字节提示随旧用例保留，逐例的提示数在 `test_results.csv`。

Toggle 用例的 16 次写 DECERR 和既有 Error Test 的一次写 DECERR 属于已核对的功能响应。它们会出现在 Scoreboard 的写错误响应计数，Checker violations 为 0。地址步进末对测试验证了 DECERR 后恢复 OKAY 和映射地址哨兵数据完整。

Random 产生 132 对、7,089 beat/方向，预填 8 笔 256-beat 写。AW/W/B/AR/R = 140/9,137/140/132/7,089，随机化失败 0。`RANDOM_SAMPLES.csv` 是 132 笔抽样记录。Burst FIXED/INCR/WRAP = 42/47/43，SIZE 0/1/2/3 = 27/35/34/36，延迟 0/1/2/3 = 29/37/36/30，ID 0–15 全部出现，随机 AxLEN 实测 0–250。

BREADY 观察采样沿每次检查 BVALID、BID、BRESP。随机组 30 个 B 响应受阻，累计 154 拍，最长 19 拍，载荷错误 0。VCD 和信号跟踪来自同次运行，`METHOD_EVIDENCE/backpressure/waveform_check.txt` 保存了按波形上升沿独立复算的结果。该组 B hold 断言有 154 次非空成功，最终 URG 合并报告 `a_kvips_b_hold` 为 768 次非空成功、0 失败。对应 X/Z 检查的 5 个属性均非空成功。

## 历史负向证据

- WSTRB 注入日志有一个 `AXI4_CHK`，`AWADDR=f000 SIZE=0 WSTRB=ff allowed=1 illegal=fe`。
- Missing WLAST 的历史 Checker 日志记录一个孤立 B，Premature WLAST 的日志记录一次预期 4、实际 2 beat 的长度错配。两份日志 UVM_FATAL 均为 0。
- AW Hold 与 4KB SVA 的旧实验来自任务说明。任务记录 4KB AW/AR 各捕获一次。在本次检索的工程路径未找到这两组原始注入日志，未纳入实测验收。可复核的 4KB 正向边界与求解拒绝证据都已重跑。
- Early-W 新注入场景单独运行。修复后唯一 UVM_ERROR 是 `AWID=3 beat=1 AWADDR=1022 SIZE=1 WSTRB=31 allowed=30 illegal=1`。VCS 进程 RC 为 0，脚本对错误日志、计数、类别和握手情况都做严格验收。

`TEST_MATRIX.csv` 汇总各例的入口、seed、状态、握手、日志。查看各次构建的完整 `commands.sh`、`compile/compile.log` 和 `regression.log` 可核对过程。
