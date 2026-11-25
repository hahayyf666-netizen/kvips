# RAM Enhanced Functional Coverage 设计审查

CentOS 原工程位于 `/home/ICer/icdv_project/kvips`，分支 `experiment/wrap-alignment` 的 HEAD 为 `71f026d085c18eee5b837965057a8ee01ec09c56`，三个 tracked 文件有改动，另有未跟踪的 ID 用例、历史备份及覆盖证据。个人 Fork 已核验为 `babcc996a61c09ba5bbee4dad2b550f0886bf617`。本轮按该 SHA 封存源码，在独立目录执行。原工作区的 Git 状态、差异和涉及源码另存校验。未执行 reset、clean、commit 或 push。

| 项目 | 源码发现与设计选择 |
|---|---|
| 原始采样 | `axi4_monitor.svh` 在 B 时用 `strb[0]`，在 RLAST 时用 `rresp[0]`。该 Monitor、13 个 coverpoint、3 个 cross、采样时机和旧排除均保持原样 |
| 完整事务 | `axi4_transaction.svh` 的 `axi4_item` 保留每拍数据、strobe 和读响应。新 Subscriber 订阅 RAM 环境现有 `env.ap`。完成前用 `mon_cb` 的实际握手核对 AW/AR 元数据、BID/RID、拍数、LAST、数据和响应。两边齐备才采样，任一回调先到均能匹配 |
| 地址和 Lane | `tb_expected_beat_addr()` 独立于 `axi4_beat_addr()` 和 DUT。继承该参考函数计算每拍地址，再按该拍合法传输区间生成掩码。首拍未对齐截去低地址字节。对 FIXED，每拍沿用同一地址和首拍车道 |
| RAM 数据行为 | `axi4_ram_slave.sv` 按总线字对齐，再按 WSTRB 更新 bytes。读口返回总线字。定向测试窄读核对协议有效 lanes，随后全字读核对选中与未选中的字节。测试复用 `axi4_closure_pair_seq`、Monitor、Scoreboard、Checker |
| 读响应 | 默认 RAM 映射 0x0000–0xFFFF，映射边界和 4 KiB 页对齐。合法 burst 困在一个页内，窗口内读 OKAY，窗口外读 DECERR。保留独立的多拍样例。当前形态的合法单个 burst 中没有 OKAY/DECERR 混合 |
| 反压归属 | RAM 每方向最多一个已接收的事务。AW/AR 可以在上一笔忙碌时等待，但只在真实握手后建立自己的上下文。W 跟当前 AW，B 对 BID，R 对 RID 及 beat index。等待从同时出现 VALID=1、READY=0 开始，握手时结束。在 B 或末拍 R 完成时统一提交采样。复位清理未完成上下文 |
| 反压驱动 | 默认 Master 的随机 READY 配置适合流量压力。需要精确控制 0/2/4/6 拍时，专项用例在本地禁用默认 Master Driver，监视器和 Checker 继续工作。测试的总线驱动只在下降沿更改信号，无 force。原 RAM RTL 和共享 VIP Driver 均未改动 |
| 验证流程 | 使用已有 VCS O-2018.09-SP2 Full64 和 UVM 1.2 选项。在隔离目录保留同模型的两份 RAM VDB，单独运行原 VIP 回归。靶向波形用原有 dump 开关 |

参考 [Arm IHI 0022H.c，A3.4 Transaction Structure](https://documentation-service.arm.com/static/602a9df190ee6824a1e02b98) 中的 burst 长度、4 KiB 约束、地址和 Byte Lane 规则。
