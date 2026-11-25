# Functional Coverage Cookbook

每节标题给出方法名称。所有数字取自本轮 RAM 增强组的独立基线与最终实测。运行入口、检查工具与波形路径见 `README.md`。

### Burst × Length

2. **适用场景** 需要验证合法 burst 类型、计数上限和结束位置。
3. **解决的问题** Burst 与 LEN 各自满覆盖时，组合仍可能缺失。
4. **原理** 按 AxLEN+1 解码拍数。以 FIXED 上限、WRAP 合法长度、4 KiB 约束定义范围。
5. **对应覆盖** `cp_burst`、`cp_len`、`cx_burst_len`。
6. **Sequence** 复用原 FIXED、INCR、WRAP 与 256-beat 正向用例。地址和数据检查用已验证的参考及 Scoreboard。
7. **VCS** 用 `run_functional_coverage.sh` 的 26 项基线运行，开启 `+DUT_FCOV_EXT=1`。
8. **URG** 查看 `grpinfo.txt` 中该 cross，再用 bin 账本确认读写方向的样本和测试。
9. **实测** 基线已达 15/15，AW 与 AR 各覆盖全部 15 组。最终维持 15/15。
10. **注意事项** 总线上的 LEN 是 beats−1。256 是 INCR 的检查点。混入 AW/AR 未接受的请求会夸大结果。
11. **迁移** AHB 检查 HBURST 与长度。FIFO 可用读写突发类别 × 长度或深度边界。

### SIZE × Start Lane

2. **适用场景** 同一总线支持不同传输宽度和未对齐地址。
3. **解决的问题** 只统计 lane 与 SIZE 的边际覆盖，遗漏合法的非对齐组合。
4. **原理** 先按 SIZE 求转移的对齐上界，首拍从真实起始地址至该上界。另用全字读回证明其他 lane 保留。
5. **对应覆盖** `cp_size`、`cp_start_lane`、`cx_size_start_lane`。
6. **Sequence** 遍历 4×8 表。单拍 INCR 写非零背景后，窄写、窄读和全字读各检查一次。
7. **VCS** 用最终清单运行 `axi4_dut_fc_size_lane_test`，保存实际 VCD。
8. **URG** 对照最终 cross 的 32 个组合，并从 `COVERAGE_BIN_ATTRIBUTION.csv` 查样本对应的测试。
9. **实测** 16/32→32/32。实际 64 次 AW 与 64 次 AR，完整覆盖双向 32 个组合。
10. **注意事项** 对齐要求随 burst 类型改变。单拍 INCR 的范围允许非对齐，WRAP 首地址受 SIZE 对齐条件限制。
11. **迁移** APB4 可用 PADDR 与 PSTRB 检查总线字节选择。AHB 用 HSIZE 与地址位定义该目标支持的组合。

### Multi-Beat WSTRB

2. **适用场景** 字节使能可在 burst 中逐拍变化。
3. **解决的问题** 首拍 strobe 不能代表后续拍，窄写的全部合法车道也可能少于整条总线。
4. **原理** 每拍以参考地址推合法 mask。先判协议越界，再分类为 Zero、All Legal、Single、Partial。
5. **对应覆盖** `cp_w_pos`、`cp_w_class`、`cx_w_pos_class`、`cx_size_w_class`。
6. **Sequence** 非零预填后使用四拍 INCR。全宽案例逐拍发 20/A5/FF/00，窄案例发 01/0C/10/00。用实际掩码控制逐字节读回模型。
7. **VCS** 跑 `axi4_dut_fc_wstrb_beat_test`，用 `WAVEFORM_VERIFIED.txt` 查真实 W/R 完成数。
8. **URG** 核对位置和 SIZE 两组交叉及本用例的 hit count。观察器在 B 完成后累积此前已接受的 W。
9. **实测** 16/16 与 13/13 均保持。该例实际 13 个 W beat，包含八个重点掩码 beat。新用例增加了逐拍数据证据，覆盖 bin 数不变。
10. **注意事项** 一条合法 lane 全使能归 All Legal。变化但未握手的 WSTRB 不能计入。以读回确保未选字节未改。
11. **迁移** 用于 SRAM byte enable、AHB byte lane、APB4 PSTRB 及其他宽总线的部分更新。

### Multi-Beat RRESP

2. **适用场景** 多拍读响应，需要确认错误响应随整帧完成。
3. **解决的问题** 仅采 `rresp[0]` 无法证明中间和最后一拍的响应。
4. **原理** 按 RID 将实际 R beat 关联到已接受的 AR。只有达到正确 RLAST 才提交逐拍事件。
5. **对应覆盖** `cp_r_pos`、`cp_rresp_beat`、`cx_rresp_pos`。
6. **Sequence** 0x5A00 预填并发四拍 OKAY 读，0x10010 发合法页内四拍读触发 DECERR。检查每拍响应、数据和末拍。
7. **VCS** 跑 `axi4_dut_fc_rresp_beat_test`，打开现有波形和已知值断言开关。
8. **URG** 用 `grpinfo.txt` 找 DECERR 的 First/Middle/Last，再比照实际 AR/R 波形和逐拍计数。
9. **实测** 5/8→8/8。VCD 包含四个 OKAY 和四个 DECERR beat。
10. **注意事项** 每笔合法 burst 留在一页内。当前 64 KiB RAM 的边界已按页对齐，各 burst 响应一致。
11. **迁移** 对多拍返回协议，分别定义整帧响应和单拍错误注入。混合响应适用于确实拥有该能力的模型。

### Backpressure × Burst

2. **适用场景** READY 由对端控制，需证明不同 burst 在等待后仍完成。
3. **解决的问题** 之前只知道有等待，无法区分 READY 档位、请求类型和实际归属。
4. **原理** 在 VALID=1、READY=0 时累加连续周期，实握手才冻结长度。根据 AW/AR 上下文关联 B、R。
5. **对应覆盖** `cx_channel_stall`、`cx_response_stall`、`cx_response_stall_length`。
6. **Sequence** 用 test-local 驱动在下降沿准备 BREADY/RREADY，覆盖 0/2/4/6 拍。在第一笔挂起时呈现下一笔地址，产生 AW/AR 停顿。
7. **VCS** 跑 `axi4_dut_fc_backpressure_burst_test`。该例使用原 Monitor、Checker 和 SVA，同时保存 VCD。
8. **URG** 按通道、请求 burst、非零停顿长度查看 cross。用独立解析脚本复算阶段边界和 payload。
9. **实测** 13/19→19/19、11/24→24/24、6/10→10/10。B/R 观察到 0/2/4/6，AW/AR 观察到 0/1/3/7，W 观察到 0/2/3 拍。
10. **注意事项** 延迟 VALID 属于源端调度。等待定义要求 VALID 已拉高。W 的范围依赖本 DUT 的三拍 throttle 和 AW-first 流程。
11. **迁移** APB 可从访问阶段 PSEL && PENABLE 起看 PREADY，AHB 可按真实 data phase 的 HREADY 统计。先确认相应等待归属。

### Coverpoint 设计

2. **适用场景** 需要把验证目标转成具有诊断意义的 bin。
3. **解决的问题** 只增加 bins 或把目标范围内所有编码混在无意义的组里。
4. **原理** 用明确的字段范围、边界和行为类别定义每个 point。
5. **对应覆盖** 例 `cp_len` 的 1/2/4/8/16/256 拍，`cp_rresp_beat` 的 OKAY/DECERR。
6. **Sequence** 挑最大值、最小值、协议转折点及实现真正可达的响应。用最小成对读写验证。
7. **VCS** 先保存 `COVERAGE_PLAN.md`，使原清单在新模型上跑基线。
8. **URG** 从 Variables 检查每项覆盖和合法分母。
9. **实测** 12 个 points 的 48 个有效 bins 在基线及最终皆命中。
10. **注意事项** 长度检查点以外的事务仍能提供其他模型的样本。按规范记录设计范围。
11. **迁移** FIFO occupancy 可选 empty、almost-full、full 和明确的边界迁移。

### Cross 设计

2. **适用场景** 不同属性相互影响，或需要识别组合级缺口。
3. **解决的问题** 单维点全部命中时，联合情形仍不充分。
4. **原理** 从一张可达性表生成组合，再给每个结构性忽略项提供依据。
5. **对应覆盖** 八组交叉。参看 `COVERAGE_PLAN.md` 与 `EXCLUSION_REVIEW.md`。
6. **Sequence** 优先为实测空白格生成小目标，避免无目的扩大随机组合。
7. **VCS** 以同版模型跑两个独立 VDB，并记录模型文件的 SHA-256。
8. **URG** 对照交叉各自期待数、命中数和忽略的组合。
9. **实测** Crosses 95/137→137/137。分母在基线前冻结。
10. **注意事项** 用 `iff` 明确采样事件。仅在 B/R 持续等待时才统计响应类型与单拍/多拍。
11. **迁移** APB 的读写 × 错误，AHB 的 burst × size 都可先用合法矩阵固定范围。

### Beat-Level Coverage

2. **适用场景** 同一包中的控制字段和有效数据随位置变化。
3. **解决的问题** 包级采样压扁了一包内的位置差异。
4. **原理** 从已匹配的 AW/AR 取得期望拍数，对每个被接受的 W/R 建立单独记录，帧通过校验后逐拍提交。
5. **对应覆盖** `cp_w_pos`、`cp_r_pos` 及对应 strobe/response cross。
6. **Sequence** 用四拍体现首拍、中间、末拍，同时用独立单拍覆盖 position=Single。
7. **VCS** 启用 `+DUT_FCOV_TRACE`，把事件行保存到每个测试的独立日志。
8. **URG** 用 `verify_functional_coverage.py` 逐 bin 与真实样本计数相等后再下结论。
9. **实测** 四个定向的波形事件与拍级采样日志精确一致。DECERR 的三种多拍位置得到新命中。
10. **注意事项** RLAST/WLAST 提前或延后、响应关联错误、复位中止都需要通过独立检查门禁。
11. **迁移** 面向 burst SRAM、DDR 控制器、stream packet 的 beat/word 层可用该模式。

### Coverage Sampling

2. **适用场景** 已有 Monitor 提供事务，另需从引脚取得握手或时序证据。
3. **解决的问题** 过早采样或在不同线程间猜测回调顺序，可能将未完成事务记为命中。
4. **原理** 同向各保留一个已完成的 Monitor 事务与总线帧。两者齐备时核对 ID、数量、数据、LAST 与响应。观察者先到和 Monitor 先到均可处理。
5. **对应覆盖** RAM 管辖的全部 `cov_ram_enhanced`，另保留共享 `cov`。
6. **Sequence** 只发送激励。为波形复核保留可重复的 ID、地址和数据。
7. **VCS** 原组与增强组分别开关。验证测试可检查 `FCOV_SUMMARY` 与 Checker 和 Scoreboard 计数。
8. **URG** 确认 RAM 有两个组且 VIP 只有一个组，各用自己的比率。
9. **实测** 原 26 项的每个继承测试的增强 bin 样本在两边精确相等。RAM 原组 73/79、VIP 原组 79/79。
10. **注意事项** 采样语义是完成事务。应以规范和目标模型定义单请求归属，特别是多个未完成和跨 ID 场景。
11. **迁移** 从 APB Monitor 复用已完成访问事件，或从 FIFO 的 read/write 接受条件提交正确采样。

### Coverage Closure

2. **适用场景** 模型已有大量有效组合，需将缺口收敛为可验收的测试。
3. **解决的问题** 百分比无法交代测了什么、哪个测试造成增量、失败出在哪里。
4. **原理** 基线冻结、缺口分类、按真实事务回放、以覆盖与行为双门禁验收。
5. **对应覆盖** 全模型 185 个 bin，以及独立的原 79-bin 历史组。
6. **Sequence** 先补基线缺口最大的 SIZE/Lane 和反压，再补多拍 DECERR。已有全部 Burst × Length 由继承测试提供。
7. **VCS** 跑 26 项 baseline、30 项 final 与 36 项 VIP guard。
8. **URG** 在原始文本中定位每一 bin，再用事件账本与每测例成绩逐项对账。
9. **实测** 143/185→185/185，全部 42 个缺口有具体贡献测试。
10. **注意事项** 记录预期错误码、排除原因、无法触发的组合及环境失败。100% 仅是冻结计划的验收结果。
11. **迁移** 对 APB、AHB、FIFO 首先分离功能采样与 RTL 代码覆盖，再保留测例到目标的归因。

## 实际排查和筛选记录

- 直接使用发布快照的 VIP shell runner 在 CentOS 启动前失败。原因是 CRLF 使 Bash 无法正确读选项，保留入口日志，用 LF 副本获得完整 36/36 结果。
- 第一版事件对账把 UVM 结尾的 `[FCOV_SAMPLE]` 汇总计数读成事件。限制到 `UVM_INFO` 独立样本行后，逐 bin 总数及 URG 的测试标识全部匹配。
- 新增 WSTRB 用例没有填补覆盖缺口。基线两组交叉已经满覆盖，该例的保留价值是针对同一真实四拍帧，独立证明 mask 变化与非选中字节保留。
- 未采用将 VALID 拉高前的空等计入反压，或发送跨 4 KiB 请求来构造混合响应。前者会计错通道握手，后者超出正向验证约束。
