# RAM Enhanced Functional Coverage 最终验收

本轮在 VCS O-2018.09-SP2 Full64 用 UVM 1.2 实跑。固定的增强口径从 **143/185（77.30%）到 185/185（100%）**。原组继续各自报告。

| 配置 | 回归 | Variables | Crosses | 原始功能覆盖 |
|---|---:|---:|---:|---:|
| RAM 增强基线 | 26/26 PASS | 48/48 | 95/137 | 143/185 |
| RAM 增强最终 | 30/30 PASS | 48/48 | 137/137 | **185/185** |
| RAM 原组，基线和最终 | 同对应 RAM 回归 | 50/52 | 23/27 | 73/79 |
| VIP Back-to-back 原组 | 36/36 PASS | 52/52 | 27/27 | 79/79 |

RAM 增强组包含 **12 个 coverpoint、8 个 cross**。基线和最终的组源码 SHA-256 相同，所有原 26 项逐项复核出的 bin 次数相同。185 个有效 bin 无剩余缺口。结构性忽略共九种组合，原因见 `EXCLUSION_REVIEW.md`。主报告使用原始 URG 分母，未加载外部排除。若在 URG 总页看到两个组的总项，请在 `groups.txt` 分别查看原组与增强组。

## 增量来自哪些测试

| 场景、用例 | 基线 → 最终 | 真实握手与行为证明 |
|---|---|---|
| Burst × Length，沿用原用例 | 15/15 → 15/15 | 实际完成的 AW、AR 分别命中全部 15 种合法组合。Subscriber 在检查整帧后采样，验证了长度、4 KiB 和 LAST。读回由原 Sequence 与 Scoreboard 校验 |
| `axi4_dut_fc_size_lane_test` | 16/32 → 32/32，+16 | AW/W/B/AR/R 均 64 次。32 个组合均有真实窄写与对应窄读。逐拍核对实际合法 strobe，完整字读回核对未选字节 |
| `axi4_dut_fc_wstrb_beat_test` | 位置 × class 16/16、SIZE × class 13/13 均维持 | 64 位四拍 INCR 的实际掩码为 20/A5/FF/00。另有 2 字节四拍 INCR，掩码为 01/0C/10/00。非零预填、逐拍不同数据和全字读回都通过。新增验证证据，+0 个新 bin |
| `axi4_dut_fc_rresp_beat_test` | 5/8 → 8/8，+3 | 0x5A00 的 4 个 OKAY beat、0x10010 的 4 个 DECERR beat。RID、响应、数据和末拍 LAST 均经 VCD 重建检查 |
| `axi4_dut_fc_backpressure_burst_test` | 五通道 13→19，B/R×Burst×档位 11→24，B/R×Burst×Length 6→10，合计 +23 | 20 个 AW 和 AR、56 个 W 和 R，20 个 B。B、R 在 FIXED/INCR/WRAP 分别覆盖 0/2/4/6 拍。AW、AR 实测 0/1/3/7 拍。W 实测 0/2/3 拍 |

W 和 R 的拍级分类来自真实 `strb[i]`、`rresp[i]`，且与实际引脚值匹配。观察组件记录各通道握手前的连续 `VALID=1 && READY=0` 周期，在每个事务完成后提交。AW/AR 等待记给该次地址握手，W/B/R 归到已接受的请求上。四项专项的 VCD 由独立 Python 解析，逐个事件与仿真采样记录对账。VCD 同时重建内存并校验读回、ID、LAST 和等候期间的 payload 稳定。Verdi 转换器已验证反压用例 VCD 可转换为非空 FSDB，日志在 `metadata/verdi-vcd-check.log`。

## 保护范围和真实限制

- 改动仅在 `tb_pkg.sv`、新 `axi4_dut_func_cov.svh`（采样与新模型）及 `axi4_dut_fc_tests.svh`（四项激励），以及本轮脚本和文档。原 `filelist.f` 的 TB include 路径已可查找新增头文件。共享 Monitor、RAM RTL、VIP Driver、Scoreboard、Checker 的源码保持一致。源码补丁和新增测试见 `source/patches/`、`source/added_tests/`。
- 新旧 RAM 回归合计两套结果、VIP 护栏均通过。UVM_ERROR、UVM_FATAL、Scoreboard mismatch、Protocol Checker errors 和 SVA failures 为 0。原 WRAP 对齐、4 KiB 约束校验保留预期求解拒绝的退出码门禁。
- 原 RAM 的六个 EXOKAY、SLVERR 相关缺口仍在。增强模型定义 RAM 已实现的 OKAY 与 DECERR。默认 RAM 窗口与 4 KiB 页对齐，与协议边界一起限制同一合法读 burst 的混合响应。
- 185/185 覆盖的是本文件所列验证空间。协议功能完整性还依赖计划、检查器和 DUT 范围。此前 VIP 护栏启动因 CRLF 在编译前返回 2，使用原 runner 的 LF 副本后 36 项全跑。失败入口的记录保存在 `metadata/`。
- VM 原工程仍为 `71f026d`，原工作区的 diff、索引、源码哈希和已有未跟踪项均已核对。全部运行发生于 `coverage_functional_enhancement/`。本轮无 commit 或 push。

`COVERAGE_BIN_ATTRIBUTION.csv` 有 185 个合法 bin 及其前后次数、完整测试归因。`COVERAGE_HOLE_INVENTORY.csv` 的 42 个基线缺口均已关闭，另列九个定义时的忽略组合。`TEST_MATRIX.csv` 列出 26+30+36 项的结果和回归日志。`WAVEFORM_VERIFIED.txt` 为独立复算简报。复用方式见 `FUNCTIONAL_COVERAGE_COOKBOOK.md`。
