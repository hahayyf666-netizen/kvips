# 在途复位验收

三个 tests 复用第二轮的单主端驱动、同一 `top.axi` 和 RAM DUT。新的 UVM event 交给 `top.sv` 原有复位发生器处理。测试在下降沿驱动，复位覆盖两个采样上升沿。Monitor、类 Checker、原始和增强功能覆盖及 Scoreboard 均在运行。[测试源码](source/added_tests/axi4_dut_code_tests.svh) · [执行命令](reports/positive/commands.sh)

| 测试 | 复位前 AW/W/B/AR/R 握手 | 接口队列 | VCD 上第一个复位上升沿 | 复位后握手 |
|---|---|---|---:|---|
| `axi4_dut_reset_aw_test` | 1/0/0/0/0 | `kvips_wr_fifo.size()=1` | 125 ns | 1/2/1/1/2 |
| `axi4_dut_reset_b_test` | 1/2/0/0/0 | `kvips_wr_done_lock_q[7].size()=1` | 195 ns | 1/2/1/1/2 |
| `axi4_dut_reset_r_test` | 0/0/0/1/0 | `kvips_rd_beats_q[7]`、`kvips_rd_lock_q[7]` 各一项 | 145 ns | 1/2/1/1/2 |

复位前 B、R 用例在 VCD 中显示对应 `VALID=1`、`READY=0`，旧事务没有响应握手。日志的 `reset_sampled` 记录接口各队列、outstanding 计数、类 Checker 队列与 WSTRB 暂存、Monitor 的待 B/R 记录以及增强覆盖观察状态均已清空。`released` 之前主动将 BREADY 和 RREADY 保持高 3 个上升沿，VCD 中 BVALID、RVALID 均为 0。AW 场景的 Monitor 已将旧 AW 取到局部事务上下文，行为通过 Scoreboard 无旧发布和复用 AWID 后正确匹配来验证。[各阶段日志](reports/positive/new-tests.log) · [逐拍核验](WAVEFORM_VERIFIED.txt)

恢复用相同 ID 7、不同地址和数据。先在 `0x200` 写两拍 `0x59ebf00d4bc3027a`，再读两拍。独立 VCD 检查 BID、BRESP、RID、RRESP、RDATA 与 RLAST，Scoreboard 在复位前及释放后各为 0 写/0 读，恢复完成为 1 写/1 读，错误为 0。旧地址 `0x100` 的内存状态未用作验收依据。测试驱动直接控制 Master 引脚，现有流水 UVM driver 的 reset-aborted response 路径属于后续专项。AW 波形（完整本地归档） · B 波形（完整本地归档） · R 波形（完整本地归档）

`kvips_wr_fifo.delete()` 的 Line 在初始复位就有命中。新增用例验证非空清理，并补齐 B、R 的三项 `foreach` 主体 Line 403、406、407。`areset_n` 的 1→0 在 `top`、`top.axi`、`top.dut` 各补 1 个方向。首跑的探针把已完成写的 WSTRB 暂存当作在途队列，复跑改成检查各阶段的期望值，复位后仍要求为 0。[复位阶段 URG](reports/reset_verified/urg/code/dashboard.txt) · [首跑日志](reports/reset/regression/axi4_dut_reset_aw_test.log)
