# KVIPS AXI4 Full 覆盖率基线

2026-11-24 在 CentOS 7 虚拟机用 VCS / URG O-2018.09-SP2 Full64、UVM 1.2 重新编译并执行。分支为 `experiment/wrap-alignment`，HEAD 为 `71f026d085c18eee5b837965057a8ee01ec09c56`。基线包含工作区已有的 ID Width、地址专项和统计改动。冻结源码和原工作区差异见 `metadata/`。

| 指标 | 基线 | 命中 / 总数 |
|---|---:|---:|
| URG 总分（六项） | 76.33% | — |
| URG 代码总分（四项） | 71.75% | — |
| Line | 84.30% | 204 / 242 |
| Condition | 55.91% | 52 / 93 |
| Toggle | 74.37% | 1,114 / 1,498 |
| Branch | 72.41% | 42 / 58 |
| Assertion（top 实例层级） | 78.57% | 22 / 28 |
| Functional Group | 92.41% | 73 / 79 |
| Functional Variables | 96.15% | 50 / 52 |
| Functional Crosses | 85.19% | 23 / 27 |

| 模块 | Line | Condition | Toggle | Branch | Assertion |
|---|---:|---:|---:|---:|---:|
| `top.dut` / `axi4_ram_slave` | 118/120 | 25/30 | 635/892 | 20/20 | — |
| `top.axi` / `axi4_if` | 73/88 | 27/37 | 476/602 | 20/34 | 22/28 |
| 仿真入口 `top` | 13/34 | 0/26 | 3/4 | 2/4 | — |
| `uvm_pkg` 定义 | — | — | — | — | 1/3 |

作用域是当前项目 VCS 自动采集的 `top` 实例及其子层级。另有 UVM 库定义报告，含该库的数据是 23/31。实际断言尝试与非空成功次数见 `reports/baseline/urg/raw/asserts.txt`。本表未加载外部排除。旧清单原样保存到 `metadata/historical-exclusions/`。模型自带的 `ignore_bins` 随源码快照保存。

基线 23/23 通过。17 项原清单包括 Lane Sweep，另加入 Burst × Size、256-beat INCR、sideband、LOCK、unaligned INCR E2E、ID Width。两项定向测试各有一次预期的约束拒绝，VCS 退出码为 2。逐例核对了固定诊断签名、预期拒绝/接受计数、协议错误、断言与 Scoreboard。其余 21 项退出码为 0，所有 23 项 UVM_ERROR / UVM_FATAL 均为 0。现有错址正向测试按预期收到 DECERR。

地址专项在独立仿真中重跑，验证了 42,717 个 beat 和 42,765 次地址比较，错误计数为 0。该结果记录于 `METHOD_EVIDENCE/functional_coverage/addr_ref_runner.log`。WSTRB、WLAST、AW hold、4KB 等故障注入证据单列。总分中的代码、功能和断言分项按上表分别解读。

采集命令和数据位于 `reports/baseline/`。编译及仿真均启用 `-cm line+cond+tgl+branch+assert`，使用固定 seed 1、逐测例 `-cm_name`、`+KVIPS_AXI4_COV=1` 及独立 VDB。功能采样默认关闭，首次试跑的 0/79 保留在 `reports/setup-probe/`，由显式使能后的正式基线替代。

- `commands.sh`、`tests.list` 和 `test_results.csv`
- `compile/compile.log`、`regression.log`、`regression/*.log`
- `coverage.vdb/`、`urg/raw/dashboard.txt`、`urg/raw/modinfo.txt`、`urg/raw/grpinfo.txt`、`urg/raw/asserts.txt`
- `urg/code/dashboard.txt` 只含四项代码指标。逐向量、分支及逐位翻转信息见完整 `modinfo.txt`。
