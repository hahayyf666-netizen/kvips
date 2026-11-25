# KVIPS RAM Functional Coverage Enhancement

GitHub 分支提供源码、逐 bin CSV、复跑脚本和可在线查阅的 URG 文本。完整本地归档另含三个源码快照、VDB、逐例仿真日志和波形。下文的归档目录和路径适用于解压本地包后的布局。

先读 `FINAL_RESULTS.md` 和 `FUNCTIONAL_COVERAGE_COOKBOOK.md`。`COVERAGE_PLAN.md` 是编译基线前冻结的口径。三份 CSV 提供逐 bin 前后命中、覆盖缺口及 92 条回归记录。归档保留三套 VDB、VCS/URG 文本和 4 个专项 VCD。

## 源码和证据

- `source/original/` 为经核验的 `babcc99` 快照。`source/baseline/` 带新增模型，`source/final/` 另外带四项定向。`source/patches/` 提供从 `babcc99` 应用的补丁。
- `reports/baseline/`、`reports/final/`、`reports/vip/` 各含真实 VDB、用例清单、日志和 URG。常用入口在 `logs/`，四个专项的 VCD 另可从 `waves/` 查看。`metadata/` 保存原工程保护核验。

## 在 VCS 环境复跑

以下从解压后的归档根目录运行。VCS/URG 需已在 PATH 可用，旧版回归门禁调用 `python`。比对脚本使用 Python 3.10+。`run_vip_guard.sh` 是既有 VIP runner 的 LF 副本。

```bash
root=$PWD
replay=$(mktemp -d)
mkdir "$replay/reports"
ln -s "$root/source" "$replay/source"

bash scripts/run_functional_coverage.sh source/baseline "$replay/reports/baseline"
bash scripts/run_functional_coverage.sh source/final "$replay/reports/final" scripts/final_tests.list
bash scripts/run_vip_guard.sh source/final \
  source/final/axi4/examples/uvm_back2back/sim/tests_questa.list "$replay/reports/vip"
python3 scripts/verify_functional_coverage.py "$replay" "$replay/checked"
```

在 Verdi/nWave 打开 `waves/` 内 VCD，展开 `top.axi`，将 ACLK、VALID/READY、ID、LAST、WSTRB 和响应放在一起。用上升沿之前的电平判断握手，随后到 `COVERAGE_BIN_ATTRIBUTION.csv` 查看该组合由哪些用例累积。
