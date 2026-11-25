# AXI4 Full VIP SLVERR 与 EXOKAY 专项

2026-11-25 在 CentOS 7 的 VCS 和 URG O-2018.09-SP2 Full64、UVM 1.2 上运行。源码基线为 `133fdd859fd9639c3d1d120cd9f7526a8a5ed578`（`axi4-coverage-closure-2026-11-25`）。VIP 用种子 1，启用 `+VIP_COV`，由 master 侧唯一 Monitor 对实际完成的事务采样。RAM DUT 独立复跑 26 项，仍采用上一轮的正向列表和覆盖开关。

## 实测功能覆盖

| 范围 | 回归 | Variables | Crosses | 总体 |
|---|---:|---:|---:|---:|
| VIP back-to-back 基线 | 33/33 PASS | 41/52（78.85%） | 26/27（96.30%） | 67/79（84.81%） |
| VIP 原 33 项 + 地址定向读写 SLVERR | 35 项 | 41/52（78.85%） | 27/27（100%） | 68/79（86.08%） |
| VIP 最终，含边带用例 | 36/36 PASS | 52/52（100%） | 27/27（100%） | 79/79（100%） |
| RAM DUT 独立复跑 | 26/26 PASS | 50/52（96.15%） | 23/27（85.19%） | 73/79（92.41%） |

VIP 基线和最终各由一个 32-bit 地址、64-bit 数据、4-bit ID、1-bit USER 的 Monitor 实例采样。两份数据库使用相同的 covergroup 源码和 79 个统计 bin。URG 正式报告未加载外部排除，沿用源码内的 default/ignore bins。最终 VIP VDB 按原 33 项重新筛选得到 67/79，覆盖前后对比来自 VIP 自身。RAM 的 6 个响应相关缺口由原 RAM 功能范围解释，适用 bin 核算仍为 73/73。

## SLVERR 和 EXOKAY 的行为证据

以下时间取自同次仿真的 VCD。证据脚本在 ACLK 上升沿采样握手，核对 BID/RID、拍数、LAST 和读回数据，再与 URG 的 test ID 对应。

| 用例 | 实际场景和关键检查 | 覆盖贡献 |
|---|---|---|
| `axi4_b2b_slverr_write_test` | 0x4000 先写入哨兵 `13579BDF2468ACE0` 并返回 OKAY。用同地址、满 WSTRB 写其反码，275 ns 收到 SLVERR。错误写前、后两次 OKAY 读回均保留哨兵 | 写 × SLVERR 已命中，事务采样从 1 次增加到 2 次。此前由 `axi4_b2b_error_rate_test` 命中 |
| `axi4_b2b_slverr_read_test` | 0x5000，ARID=B，ARLEN=3，ARSIZE=3，INCR。4 次 R 握手的 RID 均为 B、RRESP 均为 SLVERR，RLAST 为 0/0/0/1。最后一次握手在 325 ns | 读 × SLVERR 首次命中，0→1 次事务采样 |
| `axi4_b2b_exclusive_basic_test` | 对齐的 0x2000，匹配 ID、地址和读写属性，LOCK=1 且均是 8 字节单拍。205 ns 独占读、275 ns 独占写都返回 EXOKAY，315 ns 普通读回取得新值 | 读 × EXOKAY、写 × EXOKAY 在基线已有，本轮以波形复核 |
| `axi4_b2b_exclusive_fail_test` | 对齐的 0x3000，先独占读得到 EXOKAY，再由成功普通写破坏保留。335 ns 独占写返回 OKAY，375 ns 读回保留普通写的值 | 增强失败路径证据，读 EXOKAY 已属于原有命中 |

`cp_resp` 的四种响应基线已齐。SLVERR 的响应桶采样 1→3。EXOKAY 的响应桶维持 4 次，其中读 × EXOKAY 为 3 次、写 × EXOKAY 为 1 次。Monitor 在匹配的 B 握手后采样写事务。在完整 R burst 收尾后，读事务以首拍 RRESP 采样一次。因此四拍 SLVERR 只增加一次读事务命中，逐拍响应由 Sequence 和 VCD 另行验收。

错误写不更新内存是本项目 VIP Slave 模型的行为约定。独占读写需满足匹配和对齐限制，支持独占的目标在保留失效时用 OKAY 表示独占写失败。 [Arm AMBA AXI and ACE，A3.4 与 A7.2](https://documentation-service.arm.com/static/602a9df190ee6824a1e02b98)

## 12 个新增命中的去向

| 位置 | 基线 → 最终实测 | 直接对应的用例与握手 |
|---|---|---|
| `cx_write_resp` 的读 × SLVERR | 0→1 | `axi4_b2b_slverr_read_test`，245 ns AR，265/285/305/325 ns 的 4 次 R 握手 |
| `cp_prot.vals_1/2/4/5/6/7` | 各 0→1 | `axi4_b2b_sideband_coverage_test`，除预填外的 6 次 AR/R 对 |
| `cp_qos.qos4_11/qos12_14/qos15` | 各 0→2 | 同上，ARQOS 顺序为 4/12/15/4/12/15 |
| `cp_cache.cF`、`cp_region.r15` | 各 0→6 | 同上，ARCACHE=F、ARREGION=F。6 次读握手均返回 OKAY 并读回 `7654321089ABCDEF` |

这些边带命中证明接口确实传入了对应属性，并完成数据读回。权限判断、缓存策略和 QoS 仲裁各自需要具备该功能的目标模型及对应行为检查。

## 回归与证据位置

仓库保留了逐测试判定、逐拍握手和 12 个新增 bin 的归因。以下 `runs/` 路径位于完整本地归档内。 [验收证据](VIP_VERIFIED.txt)

- VIP 沿用原 33 项，增补两项 SLVERR 和一项边带测试。所有项 SIM_RC、Checker errors、UVM_ERROR、UVM_FATAL、Scoreboard mismatch 均为 0。原有 timeout recovery 按预期返回超时中止且无握手。URG 的 SVA failure 为 0。两份 VIP 断言报告都保有 `a_kvips_aw_hold`、`a_kvips_r_hold` 各一次 Incomplete。
- RAM 使用上一轮验收源码和本轮共享 Sequence 重编译，26/26 通过。其 RAM RTL、Monitor 定义及覆盖模型核对一致，原始统计分母仍为 79。
- `VIP_VERIFIED.txt` 包含逐测试判定、六组 VCD 握手和全部 12 个新增 bin 的归因。`runs/final/urg/functional/grpinfo.txt` 与 `tests.txt` 可复核 URG 取样和测试名。`runs/final/urg/attribution/` 留存两个筛选报告。`runs/ram/urg/raw/` 是本轮独立 RAM 结果。
- 更新包含 B2B 用例、共享错误 Sequence、用例列表及仅在波形开关下生效的 B2B dump scope。完整源码差异见 `vip-response-source.diff`。原实验分支和原项目目录保留，本轮变更在隔离源码内验证。

## 从归档复跑

在归档根目录使用有许可证的 VCS/URG。RAM 汇总器可用系统 Python 2.7，独立证据校验器需 Python 3。新运行输出写到新目录。

```bash
replay=$(mktemp -d)
bash scripts/run_vip_coverage.sh baseline-source \
  baseline-source/axi4/examples/uvm_back2back/sim/tests_questa.list "$replay/baseline"
bash scripts/run_vip_coverage.sh final-source \
  final-source/axi4/examples/uvm_back2back/sim/tests_questa.list "$replay/final"
bash scripts/report_vip_attribution.sh "$replay/baseline" "$replay/final"
bash scripts/run_ram_coverage.sh ram-source "$replay/ram" scripts/final_tests.list
python3 scripts/verify_vip_response.py "$replay/baseline" "$replay/final" "$replay/ram"
```
