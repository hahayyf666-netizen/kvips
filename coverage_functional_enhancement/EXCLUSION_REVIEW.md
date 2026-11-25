# 原组范围和增强组合法组合

原 Monitor 的 `cov` 及源码中的 default bin 和 ignore bin 均保持。RAM 原始 79 个 bin 中保留两种不支持的响应及四个方向交叉。未将 VIP 数据合并进 RAM，也未加载外部 URG 排除。

下表只说明新组 `cov_ram_enhanced` 在模型冻结前的结构性 `ignore_bins`。这些选择约束生成交叉成员的集合。六个长度检查点以外的合法长度不进入 Burst × Length 的计划，仍参与其余适用的覆盖。

| 源码位置及表达式（`axi4_dut_func_cov.svh`） | 组合数 | 可达性依据 |
|---|---:|---|
| `cx_burst_len.fixed_256`，`fixed_b × beats_256` | 1 | FIXED 的允许上限是 16 transfers |
| `cx_burst_len.wrap_1`、`wrap_256` | 2 | WRAP 长度只能是 2、4、8、16 transfers，并要求首地址按 transfer size 对齐 |
| `cx_size_w_class.size0_nonfull`，`size_0 × single_lane/partial_strobe` | 2 | SIZE0 最多一个有效 lane。空掩码为 Zero，启用唯一 lane 是 All Legal |
| `cx_size_w_class.size1_partial`，`size_1 × partial_strobe` | 1 | SIZE1 最多两个有效 lane。单个非全合法 lane 属于 Single，两个合法 lane 全使能属于 All Legal |
| `cx_channel_stall.w_long`，`w × long_wait` | 1 | 目标 scope 为本 RAM 的 AW-first 驱动和正常完成的事务。`axi4_ram_slave.sv` 在 AW 后置 WREADY，非末首拍后最多拉低 3 拍。故不能形成 ≥6 拍连续合法 W 等候。AXI 的其他驱动可以在 AW 前呈现 WVALID，届时应重审上限 |
| `cx_response_stall_length.wrap_single`，`B/R × WRAP × 1 beat` | 2 | WRAP 单拍不成立，B 或 R 的停顿长度不改变该限制 |

增强组的 RRESP 只有 OKAY 与 DECERR，VM 默认 64 KiB RAM 窗口和 AXI 页内 burst 保证合法事务中不存在混合映射状态。该选择未减少旧组分母。九个组合和各项实际使用的 bin 见 `COVERAGE_HOLE_INVENTORY.csv` 与两份 `urg/functional/grpinfo.txt`。 [Arm IHI 0022H.c，A3.4](https://documentation-service.arm.com/static/602a9df190ee6824a1e02b98)
