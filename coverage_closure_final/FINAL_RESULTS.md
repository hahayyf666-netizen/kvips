# KVIPS AXI4 Full 覆盖率收敛结果

最终回归于 2026-11-25 在 CentOS 7、VCS / URG O-2018.09-SP2 Full64、UVM 1.2 上完成。基线是 `experiment/wrap-alignment` 的 `71f026d085c18eee5b837965057a8ee01ec09c56` 加冻结时已有的工作区改动。测试扩展和 Early-W Checker 补丁位于 `source/final/`，也可由 `metadata/final-source.patch` 重建。原项目 HEAD、索引、已有差异、工作区文件状态和冻结源码哈希均已复核。

## 同口径覆盖率

两个 VDB 都以原始范围出报告。代码监测点的分母、源码位置、向量及方向键逐项一致，基线已有代码命中全部保留。百分点按显示保留两位的数值相减。

| 指标 | 基线 23 项 | 最终 26 项 | 差值 |
|---|---:|---:|---:|
| URG 总分（六项） | 76.33% | 89.64% | +13.31 pp |
| URG 代码总分（四项） | 71.75% | 87.26% | +15.51 pp |
| Line | 84.30%（204/242） | 92.98%（225/242） | +8.68 pp |
| Condition | 55.91%（52/93） | 81.72%（76/93） | +25.81 pp |
| Toggle | 74.37%（1,114/1,498） | 98.46%（1,475/1,498） | +24.09 pp |
| Branch | 72.41%（42/58） | 75.86%（44/58） | +3.45 pp |
| Assertion，`top` 实例层级 | 78.57%（22/28） | 96.43%（27/28） | +17.86 pp |

| 功能覆盖 | 基线命中 / 总数 | 最终命中 / 总数 | 剩余 |
|---|---:|---:|---|
| Variables | 50/52（96.15%） | 50/52（96.15%） | `cp_resp` 的 EXOKAY、SLVERR |
| Crosses | 23/27（85.19%） | 23/27（85.19%） | 上述两个响应 × 读、写 |
| Group | 73/79（92.41%） | 73/79（92.41%） | 6 个 bin |

以上分母扣除了源码模型内部的 default/ignore bins，外部排除为 0。按 RAM 响应能力审查，适用 Variables 50/50、Crosses 23/23 已全覆盖。这两个比值是人工范围核算，URG 的原始功能覆盖仍为 73/79。

| 模块 | Line 前 → 后 | Condition 前 → 后 | Toggle 前 → 后 | Branch 前 → 后 | Assertion 前 → 后 |
|---|---|---|---|---|---|
| `top.dut` / RAM | 118/120 → 118/120 | 25/30 → 25/30 | 635/892 → 883/892 | 20/20 → 20/20 | — |
| `top.axi` / 接口 | 73/88 → 73/88 | 27/37 → 27/37 | 476/602 → 589/602 | 20/34 → 20/34 | 22/28 → 27/28 |
| `top` / 仿真入口 | 13/34 → 34/34 | 0/26 → 24/26 | 3/4 → 3/4 | 2/4 → 4/4 | — |
| `uvm_pkg` / 库定义 | — | — | — | — | 1/3 → 1/3 |

## 实际贡献

以下是同一个最终 VDB 的递增筛选结果。只选原 23 项时，命中数逐项复现基线。顺序会影响新增命中的归属。

| 案例增量 | 新增 Line / Condition / Toggle / Branch / Assertion | 实际证据 |
|---|---|---|
| 数据模式、地址位行走、属性回落 | 0 / 0 / 336 / 0 / 0 | 132 种数据模式，29 个地址位，16 组 DECERR 和哨兵读回，181 AW / 197 AR |
| 合法约束随机 | 0 / 0 / 24 / 0 / 0 | Seed 1，132 对随机事务，7,089 beats/方向，0 次随机化失败，另有 8 笔预填。补全 LEN[7:4] 在 AW、AR 及内部长度寄存器的方向性缺口 |
| BREADY、真实调试与已知值检查 | 21 / 24 / 1 / 2 / 5 | 64 个 B 中 30 个延迟。154 个 stall cycle，最长 19，载荷稳定性异常 0。增量 21 Line、24 Condition、2 Branch 来自 `top` 的事务追踪与 VCD 路径。5 个 Assertion 是 `a_kvips_known_*` 的非空成功 |
| Early-W Checker 修复 | 独立台架 | 相同注入从 0 次检出变为精确 1 次。合法对照持续为 0，未合并进正向 DUT VDB |

对方法增量的复核见 `reports/final/urg/attribution/`。另有同 VDB 原 17 项的筛选报告，功能组 55/79，加入既有 6 项后为 73/79，Burst × Size 由 8/12 至 12/12。本轮新增三项的功能覆盖总数保持 73/79。BREADY 对照关闭随机 BREADY 时，64 个 B 响应均无 wait，稳定性错误仍为 0。控制运行使用独立 VDB 副本。

## Known Limitations

- 493 个基线缺口补齐 413 个，剩余 80 个，包括 17 Line、17 Condition、23 单向 Toggle、14 Branch、3 Assertion（含 2 个 UVM 库项）与 6 功能 bin。逐条原因、触发向量和源码见 `COVERAGE_HOLE_INVENTORY.csv`。Line、Condition 达到第一目标，Toggle 超过理想目标。代码总分为 87.26%，Branch 的 75.86% 仍距 85% 目标 9.14 pp。
- RAM 的 20 个分支已全命中。接口剩余 14 个分支主要是丢失/提前 LAST、孤立/溢出通道、独占响应与未配对计数等错误路径。RAM 的 5 个剩余条件是三种 WREADY 互斥状态与两种 WLAST 故障场景。历史负向实验保留各自口径。
- 23 个未翻转方向主要涉及静态开关、64 位总线非法的 SIZE[2]、复位再次拉低和 LOCK 属性。`top` 余下两个诊断条件为 0001（现有读驱动没有采样到空闲提前 RREADY）及 0010（本 RAM 的 RVALID 与活动状态互锁）。
- RAM 每方向最多一笔未完成事务，WREADY 等待 AW 握手。示例没有独占监视器与 SLVERR 响应能力。独立 Early-W 证据覆盖协议 Checker。Monitor 仅在有 AW 元数据后组包，接口内的过程式 SVA 也按 AW-first 跟踪，这两条路径仍需在支持 Early-W 的系统中另外增强。
- 正向运行保留 26/26 PASS、UVM_ERROR 和 UVM_FATAL 各 0。AW Hold 和 4KB 的旧 SVA 注入只有历史任务描述，当前工程路径内未找到原始日志，按要求未重跑。现有 WSTRB、Missing/Premature WLAST 的原始历史日志可复核。

数据见 `reports/baseline/urg/raw/`、`reports/final/urg/raw/` 与 `METHOD_EVIDENCE/`。方法与复现步骤见 `COVERAGE_IMPROVEMENT_COOKBOOK.md`。
