# RAM Enhanced Functional Coverage 基线

以 `babcc996a61c09ba5bbee4dad2b550f0886bf617` 为源码起点，加入已冻结的模型，先运行原 26 项 RAM 回归。VCS O-2018.09-SP2 Full64，UVM 1.2，Seed 1。增强模型启用 `+DUT_FCOV_EXT=1`，原组沿用 `+KVIPS_AXI4_COV=1`。

| 组 | Variables | Crosses | 原始命中 |
|---|---:|---:|---:|
| Monitor 原组 | 50/52 | 23/27 | 73/79（92.41%） |
| RAM 增强 | 48/48 | 95/137 | 143/185（77.30%） |

| 增强交叉 | 命中 | 缺口 |
|---|---:|---|
| Burst × Length | 15/15 | 0，AW 与 AR 分别都观察到这 15 组 |
| SIZE × Start Lane | 16/32 | 16，集中于 SIZE 1–3 的起始 lane |
| W 位置 × 掩码、SIZE × 掩码 | 16/16、13/13 | 0 |
| RRESP × R 位置 | 5/8 | DECERR 的 First、Middle、Last |
| 五通道 × 停顿档 | 13/19 | 6 |
| B/R × Burst × 停顿档 | 11/24 | 13 |
| B/R × Burst × 单拍/多拍（发生停顿） | 6/10 | 4 |

原回归 **26/26 PASS**。每个测试的 Monitor 事务发布与总线完整帧配对数等于 Scoreboard 计数。覆盖计划和模型在运行基线前固定。模型哈希见 `reports/baseline/model.sha256`，两个 URG 组的原始报告在 `reports/baseline/urg/functional/`，模拟命令和日志在 `reports/baseline/`。
