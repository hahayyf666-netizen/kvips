# 排除项审查

基线和最终的主报告均未加载外部 `.el`。以下范围分析以冻结源码和两份原始 URG 为依据，状态推导是 RTL 检查。

| 条目 | 当前源码位置与表达式 | 依据 | 处理及影响 |
|---|---|---|---|
| WREADY `011` | `axi4_ram_slave.sv:169`，`wr_active && !wready && (wready_stall_count != 0)` | 只有活动写的首个非末 beat 才能把计数置 3。直到计数归零才继续 W 传输，B 阶段进入时计数为 0 | 历史规则经 `-excl_strict` 实测匹配，只在独立报告排除此向量 |
| WREADY `101` | 同上 | 设置非零计数时同一个时钟更新拉低 WREADY。恢复 WREADY 的同一个时钟将计数清零 | 同上 |
| WREADY `110` | 同上 | 活动写中拉低 WREADY 仅由上述 stall 触发。末拍拉低 WREADY 时同时清掉活动位 | 同上 |
| EXOKAY、SLVERR | `axi4_monitor.svh:144–149`、`:182`，`cp_resp` 及 `cx_write_resp`，RAM `:197`、`:258–266` | RAM 写和读响应都只有 OKAY 与 DECERR。未实现独占监视器或从设备内部故障返回 SLVERR 的路径 | 原始覆盖保留 2 个 bin 和 4 个交叉。适用目标核算为 Variables 50/50、Crosses 23/23 |
| Narrow × full strobe | `axi4_monitor.svh:183–188`，`narrow && popcount(WSTRB)==8` | 64 位总线的窄传输单 beat 少于 8 个合法字节，因此不能置满 8 位 | 源码既有 `ignore_bins`，两侧 `cx_narrow_strb` 分母均为 7，适用组合 7/7 |
| Default bins | `axi4_monitor.svh:135–142`、`:157–166`，`cp_len.other`、`cp_cache.c_other`、`cp_region.r_other` | SystemVerilog default bin 记录未显式枚举的值。URG 将这三项列于 Excluded/Illegal 区，并保留采样次数 | 模型两侧一致，维持现有 coverage plan。其他长度的验证证据可从随机样本与握手日志查阅 |
| WRAP fallback 与保留 burst | `axi4_ram_slave.sv:101–109`，`total == 0` 与 `default` | 合法 LEN+1、1<<SIZE 均正。编码 3 保留。合法激励无法命中这两行 | 两行保留在主报告，分母不变 |
| LAST 故障与其他接口告警分支 | RAM `:192`，接口 SVA 源 `axi4_if_sva.svh:423–502` | 需要通过故障注入得到协议错误、孤立响应或计数异常 | 主报告保留这些项。独立验证见负向日志 |

`metadata/historical-exclusions/` 保留了四份历史规则和入口清单。`ram_dut_scope.el`、`ram_dut_scope_v2.el` 包含组级或广泛项目选择，未启用。更集中的 `ram_dut_scope_v3.el` 仅写了响应缺口，VCS 当前覆盖模型的 covergroup checksum 校验拒绝该历史规则（`UCAPI-EL-CCM`），两侧仍为 73/79。当前模型从项目源码中的 `cp_start_lane` 等最新定义生成，没有使用绕过校验参数。

`wready_unreachable.el` 的旧注释位置是 162，冻结 RTL 对应真实行为在 169。两侧严格模式报告逐向量标记 011、101、110 为 Excluded，保留 `111` 的 Covered。整体 Condition 的可选排除视图从 52/90（57.78%）至 76/90（84.44%），RAM 则为 25/27。主表继续使用 93 和 30 的原始分母。

严格复核命令、日志与结果见 `reports/exclusion-review-validated/`。对清单中其他 `Unknown` 条目继续保留原覆盖范围。
