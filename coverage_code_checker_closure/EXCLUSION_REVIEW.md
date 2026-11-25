# 剩余覆盖项与统计范围审查

本轮原始统计全部保留。VCS 编译和 URG 输出均无外部 exclusion 或提前删除覆盖项。原始 covergroup 源码中的 ignore/default bin 定义继续生效。[最新逐项清单](COVERAGE_HOLE_REVIEW.csv) · [原始命令](reports/positive/commands.sh)

| 范围 | 未命中项 | 可达性依据 |
|---|---|---|
| RAM 与接口 | AWSIZE、ARSIZE、wr_size、rd_size 的 bit 2 各两个方向 | 64-bit 数据端口合法传输为 1、2、4 或 8 B，SIZE 只能编码 0–3 |
| RAM 地址函数 | WRAP `total==0` 赋值和保留 AxBURST 的 `default` | `AxLEN+1` 与 `1<<SIZE` 均非零且乘积可表示。合法的 AxBURST 编码只含 FIXED、INCR、WRAP |
| RAM 写数据 | `wlast \|\| (wr_beat==wr_len)` 的 01、10 | 正常 Master 只在末拍拉高 WLAST。独立 Checker 的 LAST 注入保留在它自己的 VDB |
| RAM 背压 | WREADY 条件向量 011、101、110 | 条件位序是 `wr_active`、`!wready`、`stall_count!=0`。详见下文的可达状态 |
| RAM 读调试 | `rd_active`、`arvalid`、`rvalid`、`rready` 的 0010 | DUT 只在活跃期间建立 RVALID，末拍握手同周期清除两者。0001 已由提前 RREADY 补齐 |
| 接口配置 | Reset 条件 01、读独占条件 011、配置位 1→0 | 条件需关闭接口或读独占检查。运行期开关由启动 plusarg 固定，各单测保持检查使能 |
| 当前 RAM 响应 | AWLOCK 独占成功、EXOKAY、SLVERR | RAM 响应只包含 OKAY 和 DECERR，核验在 Checker-only 与 VIP 中进行。RAM 原始功能组保留 6 个不适用 bin |
| UVM 库 | `uvm_reg_map::do_read`、`do_write` 的两个断言 | 库定义项，当前测试组无尝试，保留在 Assertion 整体报表 |

## WREADY 状态复核

在 `axi4_ram_slave.sv` 中，复位令 `wr_active=0`、`wready=0`、计数=0。AW 握手使 active、ready 同时为 1，计数仍为 0。首个非终拍 W 握手同时令 WREADY=0 并将计数置为 3。计数从 3 递减，到 1 的下一拍同步清至 0 并恢复 WREADY。在计数非零时 WREADY 为 0，因此无 W 握手来提前清除 active。终拍在 WREADY 为 1 时发生，清除 active 和 WREADY，计数保持为 0。故不存在 `active=0, !ready=1, count>0`，也不存在 `active=1, !ready=0, count>0` 或 `active=1, !ready=1, count=0`。[RAM 状态逻辑](../axi4/examples/uvm_dut/tb/dut/axi4_ram_slave.sv)

## 需要保留的限制

- `W without AW` 在整个注入时段没有 AW，仅命中本项目接口过程式 Checker 的 AW-first 检查。AXI4 通道允许 W 早于配对的 AW。扩展到支持 Early-W 的互连时，应把有无最终匹配的 AW 当作不同的边界。该场景未改动支持 Early-W 的类 Checker。[Arm AMBA AXI 规范 A3.3](https://documentation-service.arm.com/static/602a9df190ee6824a1e02b98) · [接口 Checker](../axi4/sv/assertions/axi4_if_sva.svh)
- 在合法的 `r_count_overlap_control` 中，新 AR(ID=8) 和旧 RLAST(ID=7) 同拍，队列中已有 ID=8，而 `kvips_outs_r=0`。接口计数的加一与减一两条非阻塞赋值在同一块里竞争，后面的减一覆盖加一。下一拍处理第二个 RLAST 时命中第 502 行的假分支。原接口与 RAM 逻辑保持原样。[日志](reports/negative/regression/r_count_overlap_control.log) · [分支报告](reports/negative/urg/by_test/r_count_overlap_control/modinfo.txt)
- RAM 锁定写探针实测 BRESP=OKAY 且 RAM 更新数据，现有 Scoreboard 将独占未成功写留在旧期望值。该探针保留失配证据，最终 AWLOCK 以 Checker-only 的锁定 EXOKAY 路径验收。[探针日志](reports/lock_ram_probe/regression/axi4_dut_code_lock_test.log)

两个 VDB 的接口实例均为 `top.axi`，参数为 `32/64/4/1`，接口源文件和指标一致。RAM 正向的 `top` 有 DUT、UVM 和调试路径，Checker-only 的 `top` 是独立激励和响应器。原始模块定义与统计范围不同，分别交付 VDB 和 URG。逐项对照的证据位于缺口表，未生成合并总分。
