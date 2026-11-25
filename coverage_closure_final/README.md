# KVIPS AXI4 Full Coverage Closure

本目录包含可在线查看的报告、复跑脚本与部分文本证据。完整归档包含实际运行的两份 VDB、基线和最终源码、波形与日志。下载并解压归档后，从归档内的 coverage_closure_final/ 按下文复跑。 [GitHub Release](https://github.com/hahayyf666-netizen/kvips/releases/tag/axi4-coverage-closure-2026-11-25)

交付目录位于 CentOS 的 `/home/ICer/icdv_project/kvips/coverage_closure_final`。本轮使用该目录内的冻结源码和独立输出。`metadata/source-check-after.txt`、`git-status-before.txt` / `git-status-after.txt` 和两份差异记录可核验原项目保护结果。SHA 为 `71f026d085c18eee5b837965057a8ee01ec09c56`，分支为 `experiment/wrap-alignment`。

| 文件 | 内容 |
|---|---|
| `BASELINE.md`、`FINAL_RESULTS.md` | 同口径 23 与 26 项 VCS 回归，含模块明细和方法增量 |
| `COVERAGE_IMPROVEMENT_COOKBOOK.md` | 八类可复用的 Coverage Closure 方法和项目实例 |
| `COVERAGE_HOLE_INVENTORY.csv`、`COVERAGE_HOLE_INVENTORY_CONDITION_VECTORS.csv` | 493 个基线缺口及闭合状态、93 个条件向量的前后命中 |
| `REGRESSION_SUMMARY.md`、`TEST_MATRIX.csv`、`RANDOM_SAMPLES.csv` | 每例状态、覆盖意图、可重复的随机记录与独立故障注入 |
| `EXCLUSION_REVIEW.md` | 历史排除、状态推导、原始及可选报告分母 |
| `metadata/`、`source/` | 源码归档、工作区快照、前后差异、最终源树和补丁 |
| `reports/`、`logs/`、`METHOD_EVIDENCE/` | VDB、报告、完整命令、编译运行日志、波形和旧负向证据 |

## 从干净目录重跑

在安装 VCS / URG Full64 与 UVM 1.2 并具备有效许可证的 Linux 环境，把 VCS 与 URG 放入 PATH。仿真脚本需要 Bash、GNU coreutils、Git 和系统 Python（VCS 运行判定兼容 2.7）。CSV 提取器另需 Python 3。以下命令在交付目录中执行，所有新输出放在新目录。

```bash
stage=$PWD
replay=$(mktemp -d)
mkdir "$replay/baseline-source"
tar -xzf "$stage/metadata/source-before.tar.gz" -C "$replay/baseline-source"
bash "$stage/scripts/prepare_final_source.sh" \
  "$stage/metadata/source-before.tar.gz" "$stage/metadata/final-source.patch" "$replay/final-source"

bash "$stage/scripts/run_coverage_closure.sh" \
  "$replay/baseline-source" "$replay/baseline"
bash "$stage/scripts/run_coverage_closure.sh" \
  "$replay/final-source" "$replay/final" "$stage/scripts/final_tests.list"
bash "$stage/scripts/report_coverage_attribution.sh" "$replay/baseline" "$replay/final"
urg -full64 -dir "$replay/baseline/coverage.vdb" -metric line+cond+tgl+branch \
  -format both -show ratios -cond ids -report "$replay/baseline/urg/code"
```

主报告位于各运行目录的 `urg/raw/dashboard.txt`。如果要读取最终原始 VDB，也可在支持此 VCS 版本的 Verdi Coverage 工具中直接打开 `reports/final/coverage.vdb`。若只想重跑单项，可按对应正向 `commands.sh` 使用该次新编译的 simv 和独立的测试数据库。复用正式 VDB 报告时通过 `urg -show availabletests` 获取 VCS 真实 test location，再用 `urg -tests` 筛选。

```bash
bash "$stage/scripts/run_early_w_checker.sh" "$replay/baseline-source" "$replay/early-before" before
bash "$stage/scripts/run_early_w_checker.sh" "$replay/final-source" "$replay/early-after" after
bash "$stage/scripts/run_bready_control.sh" "$replay/final" "$replay/bready-control"
bash "$stage/scripts/review_exclusions.sh" \
  "$replay/baseline" "$replay/final" "$stage/metadata/historical-exclusions" "$replay/exclusion-review"
python3 "$stage/scripts/coverage_inventory.py" \
  "$replay/baseline/urg/raw" "$replay/baseline-source" "$replay/COVERAGE_HOLE_INVENTORY.csv" \
  "$replay/final/urg/raw" "$replay/final-source"
python3 "$stage/scripts/build_test_matrix.py" "$replay/baseline" "$replay/final" "$replay"
python3 "$stage/scripts/check_bready_vcd.py" \
  "$replay/bready-control/kvips_axi4_dut.vcd" "$replay/final/regression/kvips_axi4_dut.vcd"
```

纯地址算法是 `axi4_dut_addr_ref_test`，使用已有 `run_vcs.sh` 单独编译，记录 `+ADDR_REF_ITERS=1000 +ADDR_REF_SEED=1`。历史负向日志原样保留，Early-W 台架关闭 AW-first 的接口过程检查，只实例化 Checker，不进入 DUT VDB。参考 `REGRESSION_SUMMARY.md` 的正向与故障注入验收。
