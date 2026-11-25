# AXI4 Code Coverage 与 Protocol Checker 第三轮交付

起点是 `0dc9b63c5e5d4d6cb31a2877dd608d05594b2cde`。完整结果从 [最终报告](FINAL_RESULTS.md) 开始。所有最终读数均来自 CentOS 7 的 VCS/URG O-2018.09-SP2 Full64 实跑。

| 内容 | 入口 |
|---|---|
| 最新 30 项基线与覆盖口径 | [基线](BASELINE.md) |
| 74 条基线缺口与最终归因 | [缺口审查 CSV](COVERAGE_HOLE_REVIEW.csv) |
| 11 项过程式注入、1 项 SVA 注入、2 项对照 | [负向矩阵 CSV](NEGATIVE_TEST_MATRIX.csv) |
| 三类在途复位、队列与读回 | [复位](RESET_IN_FLIGHT_RESULTS.md) |
| 非空成功、预期失败、开关验证 | [断言](ASSERTION_RESULTS.md) |
| 逐拍波形结果 | [波形核验](WAVEFORM_VERIFIED.txt) |
| 不可达和统计边界 | [范围审查](EXCLUSION_REVIEW.md) |
| 可迁移的方法和实际复现步骤 | [Cookbook](CHECKER_COVERAGE_COOKBOOK.md) |
| 源码差异、哈希和工作区校验 | [补丁](source/patches/positive-tests.patch) · [基线哈希](metadata/baseline-source.sha256) · [最终哈希](metadata/final-source.sha256) · 原工作区（完整本地归档） |

## 在 CentOS 7 用现有 VCS 环境复跑

GitHub 版本包含源码、报告、逐例 URG 文本和复跑脚本。完整本地归档包含原始 VDB、VCD 和冻结副本。报告中的本地归档路径可用复跑结果重建。

在仓库根目录运行以下命令。使用现有 CentOS VCS 环境。负向结果和正向结果分别写入独立目录。

```bash
repo=$(git rev-parse --show-toplevel)
stage="$repo/coverage_code_checker_closure"
replay=$(mktemp -d)
mkdir "$replay/reports"
git worktree add --detach "$replay/baseline-source" 0dc9b63c5e5d4d6cb31a2877dd608d05594b2cde
bash "$stage/scripts/run_code_checker_closure.sh" baseline "$replay/baseline-source" "$replay/reports/baseline"
bash "$stage/scripts/run_code_checker_closure.sh" positive "$repo" "$replay/reports/positive"
bash "$stage/scripts/run_code_checker_closure.sh" negative "$repo" "$replay/reports/negative"
bash "$stage/scripts/run_code_checker_closure.sh" vip "$repo" "$replay/reports/vip"
```

使用 Python 3.10 或更新版本运行后处理。若 CentOS 只装了 Python 2，可以把回放目录及本交付副本复制到 Windows 项目目录，在该处运行同样的 Python 命令。

```bash
python3 "$stage"/scripts/verify_results.py "$replay" "$replay/baseline-source"
python3 "$stage"/scripts/review_coverage.py "$replay/baseline-source" \
  "$replay/reports/baseline/urg/all" "$replay/COVERAGE_HOLE_REVIEW.csv" \
  --positive "$replay/reports/positive/urg/all" --final-source "$repo" \
  --checker "$replay/reports/negative/urg/all"
```

## 定位原始证据

GitHub 的报告目录提供 URG 文本、覆盖率矩阵和定向日志。完整本地归档或复跑结果另含各组 VDB、完整仿真日志和 VCD，可用 Verdi 复核波形。锁定写探针的失配日志位于 `reports/lock_ram_probe`。
