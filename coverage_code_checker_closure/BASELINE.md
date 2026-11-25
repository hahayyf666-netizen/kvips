# 第三轮代码覆盖率基线

## 源码与工作区

基线来自 `0dc9b63c5e5d4d6cb31a2877dd608d05594b2cde` 的冻结源码，位于 `source/baseline/`。虚拟机原仓库的分支是 `experiment/wrap-alignment`，HEAD 为 `71f026d085c18eee5b837965057a8ee01ec09c56`，有 3 个已修改文件和既有未跟踪备份。所有编译、仿真和修改均在项目下的隔离源码副本中进行。原索引、工作区差异与状态已逐项复核。原工作区校验（完整本地归档） · [冻结源码 SHA-256](metadata/baseline-source.sha256)

## 2026-11-25 实跑

CentOS 7、VCS 与 URG O-2018.09-SP2 Full64、UVM 1.2。以 Seed 1 重跑第二轮的 30 项测试。VCS 编译和运行均使用 `-cm line+cond+tgl+branch+assert`。URG 保留原始覆盖率分母，外部排除为 0。测试名单、编译、仿真和 URG 参数可从原始文件追溯。[测试列表](reports/baseline/tests.list) · [完整命令](reports/baseline/commands.sh) · 工具版本（完整本地归档） · 原始 VDB（完整本地归档）

| 指标 | 命中 / 总数 | URG |
|---|---:|---:|
| Line | 225/242 | 92.98% |
| Condition | 76/93 | 81.72% |
| Toggle | 1,475/1,498 | 98.46% |
| Branch | 44/58 | 75.86% |
| 项目 SVA 非空成功 | 27/28 | 96.43% |
| 定义整体 Assertion 非空成功 | 28/31 | 90.32% |
| 四项代码覆盖率总分 | — | **87.26%** |

| 模块或实例 | Line | Condition | Toggle | Branch | Assertion |
|---|---:|---:|---:|---:|---:|
| `top.dut` / `axi4_ram_slave` | 118/120 | 25/30 | 883/892 | 20/20 | — |
| `top.axi` / `axi4_if` | 73/88 | 27/37 | 589/602 | 20/34 | 27/28 |
| `top` 的仿真入口与跟踪逻辑 | 34/34 | 24/26 | 3/4 | 4/4 | — |
| `uvm_pkg` 的定义项 | — | — | — | — | 1/3 |

URG 对受监测模块给出代码分项。接口行、条件与分支包含 `axi4_if_sva.svh` 中的过程式 Checker。UVM 类 Checker、Monitor、Scoreboard 和第二轮 Subscriber 的行为由回归日志和波形验证，代码分母来自 URG 实际列出的三个模块。UVM 库的三个 Assertion 定义项单独记录。[代码 Dashboard](reports/baseline/urg/code/dashboard.txt) · [模块详细项](reports/baseline/urg/all/modinfo.txt) · [断言报告](reports/baseline/urg/assertions/asserts.txt)

本次重跑与第一轮最终结果的四项代码分母及命中数相同。第二轮新增类和 covergroup 反映在功能报告中。基线 30/30 PASS，RAM 原始模型 73/79、增强模型 185/185。两条预期约束拒绝由原回归验收条件核对求解器签名。剩余 74 个代码及断言缺口均从本次原始 URG 报告解析。[回归表](reports/baseline/test_results.csv) · [功能覆盖](reports/baseline/urg/functional/grpinfo.txt) · [缺口表](COVERAGE_HOLE_REVIEW.csv)
