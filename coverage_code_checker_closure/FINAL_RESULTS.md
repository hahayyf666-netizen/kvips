# KVIPS AXI4 Full 第三轮验收结果

本轮使用冻结提交 `0dc9b63c5e5d4d6cb31a2877dd608d05594b2cde` 在 CentOS 7 上实跑 VCS 和 URG。第 2 轮 RAM 的 30 项测试、5 项新增 RAM 测试及 VIP 的 36 项测试通过。12 项独立负向测试精确检出预期错误，两项对照均复核。源码补丁只涉及 DUT 测试台入口和新增测试。RAM RTL、接口 SVA、类 Checker、Monitor、Scoreboard 与功能覆盖模型做了逐文件校验。[源文件核验](logs/production-source-verification.txt) · [正向补丁](source/patches/positive-tests.patch)

## RAM 正向覆盖率

| 指标 | 最新 30 项基线 | 最终 30 + 5 项 |
|---|---:|---:|
| 四项代码覆盖率总分 | **87.26%** | **87.98%** |
| Line | 225/242（92.98%） | 238/252（94.44%） |
| Condition | 76/93（81.72%） | 77/93（82.80%） |
| Toggle | 1,475/1,498（98.46%） | 1,480/1,498（98.80%） |
| Branch | 44/58（75.86%） | 44/58（75.86%） |
| 项目 SVA 非空成功 | 27/28（96.43%） | 27/28（96.43%） |
| 整体 Assertion 非空成功 | 28/31（90.32%） | 28/31（90.32%） |

最新基线与第一轮最终四项代码分母、命中数一致。最终新增 10 个 `top.sv` Line 监测项，全部由复位控制及其设置路径执行。同基线的 242 个 Line 命中从 225 增至 228，新增的三个可归因到接口的 B/R 清理主体。另有提前 RREADY 的条件向量 0001、三个层级的复位下降沿与 ARLOCK 的两个翻转方向。正向 Branch 维持 44/58，未达到 50/58 和 85% 的目标，代码总分未达到 90%。[基线原始结果](reports/baseline/urg/code/dashboard.txt) · [最终原始结果](reports/positive/urg/code/dashboard.txt) · [逐项缺口](COVERAGE_HOLE_REVIEW.csv)

| 统计模块 | 最终 Line | 最终 Condition | 最终 Toggle | 最终 Branch |
|---|---:|---:|---:|---:|
| `top.dut` / RAM | 118/120 | 25/30 | 884/892 | 20/20 |
| `top.axi` / AXI 接口过程式逻辑 | 76/88 | 27/37 | 592/602 | 20/34 |
| `top` / 仿真入口 | 44/44 | 25/26 | 4/4 | 4/4 |

旧 30 项在最终 VDB 的筛选结果为 Line 229/252、Condition 76/93、Toggle 1475/1498、Branch 44/58。其 Line 增量来自 4 个在原用例中就运行的新增 TB 监测点。接口、RAM 的代码监测点及功能覆盖模型沿用原定义。各项分母和合并条件见范围审查。[最终模块详情](reports/positive/urg/all/modinfo.txt) · [最终旧 30 项切片](reports/positive/urg/by_test/legacy_30/dashboard.txt) · [排除项审查](EXCLUSION_REVIEW.md)

## 独立 Checker-only

| 统计输入 | `top.axi` Branch | 诊断 |
|---|---:|---|
| RAM 正向基线与最终 | 20/34 | 正向过程式 Checker 与 SVA 错误 0 |
| 11 项 W/B/R 定向注入 | 33/34 | 14 条预期过程式 `$error` |
| 12 项注入和 2 项对照 | **34/34** | 另外 1 次真实 AW Hold SVA 失败，意外错误 0 |

11 项注入命中基线缺失的 13 个接口 Branch。行号对应 `axi4_if_sva.svh`。12 个诊断分支落在 423、428、431、434、442、456、461、478、485、488、491、494。孤立 B 同时命中 465 的 outstanding count 为零。剩余 502 在独立并发读对照中命中。该处实测队列已有第二笔 AR 但计数为零，须结合原实现的 NBA 顺序判断。34/34 表示独立台架的接口 Branch 命中。该台架还有测试代码，其全范围 Branch 为 51/55、代码总分 75.60%。[逐例命中和签名](NEGATIVE_TEST_MATRIX.csv) · [11 项原始切片](reports/negative/urg/by_test/required_faults/modinfo.txt) · [独立原始报告](reports/negative/urg/all/modinfo.txt)

RAM 自身 Branch 20/20。RAM 正向的余下 14 个分支全部在接口，涉及异常 W/R 末拍、无上下文 B/R、EXOKAY 与非锁定请求组合，以及 outstanding 的两个零值分支。独立台架和 RAM 各有自己的 `top` 模块定义，保留独立 VDB 和原始分母。详见 [范围审查](EXCLUSION_REVIEW.md)。

## 功能与复位守护

| 范围 | 回归 | 功能覆盖 |
|---|---:|---:|
| RAM 基线 | 30/30 | 原始 73/79、增强 185/185 |
| RAM 最终 | 30/30 原用例 + 5/5 新用例 | 原始 73/79、增强 185/185 |
| VIP Back-to-back | 36/36 | 79/79 |

正向最终 UVM_ERROR、UVM_FATAL、类 Checker、Scoreboard mismatch 及 SVA 失败均为 0。RAM 保留预期的 DECERR 功能场景。负向每例复位后均通过独立的写、读对照检查。AW 未发送数据、B 阻塞、R 阻塞的三种在途复位都采到对应队列的非空状态、复位归零及旧 B/R 无残留。复位后复用同一 ID 的新写读正常完成。VIP 的指定地址 SLVERR 写内存保护、SLVERR 读、EXOKAY 成功读写与独占失败的内存验证都通过。[原 30 项回归](reports/positive/test_results.csv) · [新增 RAM 日志](reports/positive/new-tests.log) · [RAM 功能覆盖](reports/positive/urg/functional_all/grpinfo.txt) · [VIP 功能覆盖](reports/vip/urg/functional/grpinfo.txt) · [复位结果](RESET_IN_FLIGHT_RESULTS.md) · [断言结果](ASSERTION_RESULTS.md)

## 阶段记录

| 阶段 | 操作与文件 | 验收或下一步 |
|---|---|---|
| 1 | `git symbolic-ref --short HEAD`、`git rev-parse HEAD`、`git status --short`、`git diff --stat`、`git diff --check`，备份原差异和源码哈希 | 确认原 HEAD 为 71f026d，选择 0dc9b63 的隔离源码 |
| 2 | `scripts/run_code_checker_closure.sh baseline` | 30/30，基线 87.26%，原始 URG 存入 `reports/baseline` |
| 3 | `scripts/review_coverage.py` | 从最新 URG 逐项核对 74 个缺口及触发条件 |
| 4 | `axi4_dut_code_tests.svh` 与 TB 复位 event | 三类复位验证，补三项接口 Line 与三项复位 Toggle |
| 5 | `axi4_checker_only_top.sv`、`scripts/run_checker_cases.sh` | W/B/R 注入、AW Hold、复位后对照与计数重现，独立日志与 VCD |
| 6 | `axi4_dut_arlock_toggle_test`、`axi4_dut_idle_rready_test`、`locked_ok_control` | RAM RREADY 0001 与 ARLOCK 双向，独立 AWLOCK 非空成功 |
| 7 | `scripts/run_code_checker_closure.sh` 的 positive、negative、vip 模式 | 三套不同用途的 VDB，原始分母保留 |
| 8 | `scripts/report_test_details.sh`，URG `-show availabletests` 后用 `-tests` | 逐例归因 13 个注入 Branch 与 1 个并发 Branch |
| 9 | `scripts/verify_results.py`、`scripts/verify_waveforms.py` | 正向 30+5、注入 12、对照 2、VIP 36，牵涉的波形逐拍检查 |
| 10 | 本报告、缺口表、复跑入口和 Cookbook | 见交付索引及复跑步骤 |

## 已知限制

- AW-first 是现有接口过程式检查的假设。AXI4 允许写数据先于匹配写地址，`W without AW` 仅验证当前接口行为。类 Checker 的 Early-W 缓冲继续由历史测试覆盖。[Arm AMBA AXI 规范 A3.3](https://documentation-service.arm.com/static/602a9df190ee6824a1e02b98)
- 并发 AR/RLAST 的计数丢更新已在独立对照复现。RAM 每方向只有一笔在途请求，本轮仅记录可复现证据。
- RAM 锁定写探针的 Scoreboard 失配已保留。最终 AWLOCK 由 Checker-only 的合法属性和 VIP 的独占成功/失败覆盖。RAM 中保留锁定读属性与数据检查。
- 64-bit SIZE[2]、保留 Burst、WREADY 状态互斥、WRAP 的零周长、RVALID 与活动互锁等项保留在原始范围。库断言两个无尝试的定义项保留。
- 在途复位验证以单一直接引脚驱动为 Master。测试范围包含 RAM、接口、类 Checker、Monitor、Scoreboard 与增强 coverage Subscriber。流水 UVM Master driver 的复位中止响应未在此次新增场景中覆盖。

可迁移的复位控制、握手注入、真实 SVA 对照、合法属性和 URG 溯源方法见 [Checker Coverage Cookbook](CHECKER_COVERAGE_COOKBOOK.md)。本轮未创建提交或推送。
