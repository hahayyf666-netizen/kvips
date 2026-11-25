# KVIPS AXI4 Full 覆盖率收敛手册

先按 `README.md` 生成两份同配置的 VDB。用 `reports/baseline/urg/raw/dashboard.txt` 确认分母，随后用 `modinfo.txt` 定位模块和条件，用 `grpinfo.txt` 查功能 bin，用 `asserts.txt` 查断言的真实成功和失败。下文的日志和源码路径以交付目录为起点。凡本轮归因数据，均取同一个最终 VDB 的递增筛选视图。历史负向和纯算法有自己的运行记录。

AXI 的通道、burst 与合法性规则可查阅原规范。 [Arm AMBA AXI and ACE Protocol Specification](https://developer.arm.com/documentation/ihi0022/h/)

## 一、定向激励

### 最大 INCR 长度与 Burst × Size

1. **适用场景** 需要验证计数器、终拍、地址更新及 burst 与 size 的合法组合。
2. **主要解决的问题** 短交易无法独立证明长度上限，单测各类型也可能遗漏交叉组合。
3. **可能提升的指标** Toggle、Condition、Functional。
4. **原理** AXI4 的 AxLEN 是 beat 数减一。256-beat INCR 令 8 位 beat 计数遍历完整范围。FIXED 地址固定，INCR 递增，WRAP 在自然容器回绕，分别选 1/2/4/8 字节传输。
5. **操作步骤** 在 `source/final/axi4/examples/uvm_dut/tb/tb_pkg.sv` 查 `axi4_dut_len_256_test` 与 `axi4_dut_burst_size_cross_test`。按 `reports/final/commands.sh` 回放，分别检查 AW、AR 的 LEN/SIZE/BURST 及 W、R 最后一次握手。
6. **实际案例** `ADDR=0x8000 LEN=255 SIZE=3`，单向 2,048 字节落在同一 4 KiB 页。已有 FIXED/INCR/WRAP 定向也进入同一回归。
7. **前后效果** 原 17 项筛选到 23 项统一基线，Burst × Size 从 8/12 到 12/12，`len_256` 采样 2→4。独立最大长包的 W、R 各 256，错配 0。
8. **验收方法** 检查完成数为 1 AW、1 B、1 AR，W=R=256，读回和 LAST 均正确。按交叉 bin 明细确认新增组合。
9. **注意事项** FIXED/WRAP 受各自长度上限约束，WRAP 合法长度为 2/4/8/16 beats。随机抽样未碰到最大值时保留这条定向。
10. **复用建议** 在 FIFO 用深度、深度−1、复位清空作边界，在 AXI、AHB 按协议的最大允许 burst 与地址窗口拆分验证。

### 4 KiB 页边界与 RAM 地址译码边界

1. **适用场景** 协议地址计算与地址译码都涉及上下边界。
2. **主要解决的问题** 起止地址相邻时容易出现 off-by-one，未映射地址可能错误别名到有效 RAM。
3. **可能提升的指标** Condition、Functional、地址与响应 Toggle。
4. **原理** AXI 页边界是请求合法性。RAM 的映射窗口是响应业务。协议合法的一拍访问可落在未映射区并返回 DECERR。
5. **操作步骤** 运行 `axi4_dut_4kb_boundary_test`，核对约束接受/拒绝和实际握手。再运行 `axi4_dut_closure_toggle_test`，在每次高位 DECERR 后读映射地址哨兵，逐 VDB 报告查地址和响应位。
6. **实际案例** 2×8B 的 INCR 从 0x1FF0 起始通过，从 0x1FF8 起始会跨页并被拒绝。映射区末字 0xFFF8 正常读写，0x10000 是第一个未映射地址。
7. **前后效果** 基线与最终均获得 1 个合法边界读写对和 1 个求解拒绝。正向错址写/读从 1 对增至 17 对，新增 16 对的后续哨兵读均正确。
8. **验收方法** 看预期的求解器诊断签名及合法事务响应。对错址要求 B/R 均为 DECERR，对哨兵单独比对数据。
9. **注意事项** 已有 4KB SVA 错误注入属于历史证据。该注入日志未在本次归档找到。本例的拒绝发生在求解阶段。
10. **复用建议** 在 APB/AXI interconnect 中将协议地址边界、slave select 译码边界、目标内部深度边界分别放入计划。

### Narrow、Unaligned、Lane Sweep 与部分写

1. **适用场景** 总线宽于目标访问字节，且协议支持 byte enable 或非对齐地址。
2. **主要解决的问题** WSTRB 偏移、INCR 首 beat 非对齐、部分修改破坏其他字节。
3. **可能提升的指标** Functional 的 Start Lane 与 Narrow × Strobe，WSTRB Toggle。读回错误可直接定位。
4. **原理** 从 AWADDR、AWSIZE、burst 类型、beat index 求出容许的 lane。非零背景可暴露本应保留的字节被清零。零掩码测试验证 no-op。
5. **操作步骤** 先按完整字宽预填，再扫地址最低三位。查 `axi4_dut_lane_sweep_test`、`axi4_dut_narrow_directed_test`、`axi4_dut_unaligned_incr_e2e_test` 和原 Strobe Test。对每拍把 mask 与完整字读回关联。
6. **实际案例** Lane Sweep 的首笔预填 0x6000、WSTRB=FF、DATA=A1A2A3A4A5A6A7A8。已有地址参考模型另测首拍与后续 beat 共同约束。
7. **前后效果** 基线到最终均为 Start Lane 8/8、Narrow × Strobe 7/7。Lane Sweep 16 AW、16 AR、错误 0。本轮随机增加大量合法的零位与部分位掩码样本。
8. **验收方法** 先验证实际握手携带的掩码，再用 Scoreboard 完整字比对，最后核对覆盖组的 bin 和样本出处。
9. **注意事项** 组模型对写事务采的是首 beat 的 strobe popcount。Checker 及数据检查逐 beat，二者应各自验证。
10. **复用建议** APB4 的 PSTRB、AHB 至字节 SRAM 的 lane 适配、FIFO 部分更新都可复用非零背景和位移掩码。

### ID 宽度往返

1. **适用场景** 请求与响应 ID 经过截断、队列或跨层传递。
2. **主要解决的问题** 只发 ID 0 会遗漏高位宽度问题，单独置 1 也可能看不到回落。
3. **可能提升的指标** AWID/ARID/BID/RID Toggle 与响应配对检查。
4. **原理** 同次仿真发 0→全 1→0，让每个位都实质完成双向边沿，并检查响应匹配。
5. **操作步骤** 用 `source/final/axi4/examples/uvm_dut/tb/axi4_id_width_test.svh` 与 `axi4_dut_id_width_test`。抓 AW、B、AR、R 握手而非等待期值。
6. **实际案例** ID 宽 4，分别发 0x0、0xF、0x0 三写三读。
7. **前后效果** 合并基线和最终的相关四通道 ID 都维持 4/4 位双向，重跑旧 ID 专项三读三写均通过。本轮随机中 ID 0–15 各至少出现 4 次。
8. **验收方法** 比较同笔请求和应答、Scoreboard 数据和逐位报告。正向日志的 AW/W/B/AR/R 均为 3。
9. **注意事项** 单笔在途的 RAM 可证明宽度与响应匹配。ID 重排序需能维持多笔在途的 DUT。
10. **复用建议** 用实际参数扩展掩码。回归保留从零到最大值再回零的顺序。

## 二、数据模式

### 全零、全一、交替位与 Walking 1/0

1. **适用场景** 数据位粘连、相邻位耦合或读写通路换位的验收。
2. **主要解决的问题** 总线虽有翻转统计，仍需证明已知数据经过实际写入再读回。
3. **可能提升的指标** WDATA/RDATA Toggle 和数据端到端检查信心。
4. **原理** 0 与 F 切换整条总线，AA/55 使相邻位反相，Walking 1/0 把每根数据位分别置于反向背景。
5. **操作步骤** 在 `axi4_closure_toggle_seq::body` 找到 4 个固定模式和 64×2 个走位模式。运行 `axi4_dut_closure_toggle_test`。每笔使用满 strobe 的对齐读写并比较 64 位。
6. **实际案例** 0x20 地址写读 132 种模式，包括 `0000000000000000`、`FFFFFFFFFFFFFFFF`、`AAAAAAAAAAAAAAAA`、`5555555555555555`。
7. **前后效果** WDATA 与 RDATA 的 64 位双向翻转在基线和最终均已全命中。本轮提供 132 次显式的定向写读比较。整个定向用例增量 336 个方向主要来自地址、响应、边带。
8. **验收方法** 核对模式计数和完整数据匹配。全部新增地址与数据定向共 181 写、197 读、错配 0。
9. **注意事项** 将预期数据从原始模式保存下来。每次写都配读，流水时用事务匹配隔离序列次序和到达次序。
10. **复用建议** 依位宽生成一位掩码和取反，保留全 0/1 与交替模式作为快速诊断样本。

### 地址、响应、USER 与属性回落

1. **适用场景** AWADDR/ARADDR 或内部地址寄存器有成段的高位未翻转。
2. **主要解决的问题** 只用小窗口地址无法使高位变化。单独发一次错误响应可能只覆盖 0→1。
3. **可能提升的指标** 多级端口/寄存器 Toggle，边界功能检验。
4. **原理** 逐位计算 1<<i。区分映射内读写与未映射合法事务。每次返回 OKAY 验证恢复，并用不重写的哨兵发现别名。属性与 USER 显式发有效值后回 0。
5. **操作步骤** 在 `axi4_coverage_closure_tests.svh` 复用 `word_pair`。用 `urg -tests` 生成的 `reports/final/urg/attribution/stage_0` 和 `stage_1` 逐位对照状态。
6. **实际案例** WALK i=3–31，低三位由 Lane Sweep 覆盖。16 个未映射高位场景都用全 strobe、单 beat，分别检查 DECERR 与地址 0 的哨兵。边带用 USER=1、CACHE=F、PROT=7、REGION=F，再回 0。
7. **前后效果** 增量 Toggle 1114/1498→1450/1498，增加 336 个方向。29 个地址位场景、16 组 DECERR、16 次哨兵读均通过。
8. **验收方法** URG 对 AW/AR 及 `wr/rd_start_addr`、`wr/rd_addr` 查地址位，对 BRESP/RRESP 和 USER、属性查两个方向。对应错误都要符合期望响应。
9. **注意事项** 根据地址译码规划合法但未映射的交易。ID 双向翻转可用上一类的 0/F/0 事务。本轮复用现有 ID 测试。
10. **复用建议** 对 APB PADDR 也可用地址 walking 和哨兵。只在已定义错误返回时检查预期错误码。

## 三、约束随机

### 按协议形状随机并固定种子

1. **适用场景** 定向填好基础缺口后需要组合、时序与数据差异。
2. **主要解决的问题** 通用 item 约束 INCR 默认值限制 burst 多样性，固定 LEN256 一项又不能保证此前存在 0→1 过渡。
3. **可能提升的指标** LEN、地址、数据 Toggle 与已有功能交叉的样本覆盖。
4. **原理** 先定 burst 再约束 len，随机地址位于对齐页的前半，留出最多 2,048B 的 burst 空间。窄写把随机 mask 与合法 lane 取交集。AW/AR/W 间隔随机 0–3，READY 随机反压在有实际队列的 Pipeline 专项启用。
5. **操作步骤** 跑 `axi4_dut_closure_random_test`，固定 `+ntb_random_seed=1`。查 `axi4_closure_random_shape`、独立地址参考输出和预填模型。日志用 `CLOSURE_RANDOM_SAMPLE` 重放每笔地址、类型、长度、大小、ID 和延迟。
6. **实际案例** 四个 4KiB 页，132 个有效形状，7,089 个 beat/方向，另有 8 笔初始化写。FIXED/INCR/WRAP 42/47/43，SIZE 0/1/2/3 为 27/35/34/36。
7. **前后效果** 定向阶段 1450/1498→随机后 1474/1498，新 24 个 LEN 方向。随机失败 0、数据错配 0，LEN 的按位 OR=FF、AND=00。
8. **验收方法** 验证握手数量、地址不越页、请求形状合法、响应和数据正确。抽读 `RANDOM_SAMPLES.csv` 检查 ID 全范围、实际长度和延迟分布。用同 VDB `stage_1` 与 `stage_2` 归因。
9. **注意事项** 保持定向的 256-beat INCR。随机实测最长 251 beats，达到位翻转目标。改约束前要看分布，保留失败日志。
10. **复用建议** 每种协议约束放在形状生成器。对随机生成地址和宽度，用独立 reference 检查掩码和页边界。

## 四、负向验证

### WSTRB、Missing WLAST 与 Premature WLAST 的单故障注入

1. **适用场景** 正向通过时仍需确认 Checker 真正能找出协议错误。
2. **主要解决的问题** WSTRB 超出 byte lane、末 beat 缺少 WLAST、非末 beat 提前 WLAST。
3. **可能提升的指标** 负向环境可命中异常代码或 Assertion Failure，提供 Checker 检错证据。
4. **原理** 保持其他事务合法，只改一个信号或一处字段，按预期的第一处故障和可能级联项验收。
5. **操作步骤** WSTRB 的既有入口是 `+KVIPS_BAD_WSTRB`。WLAST 使用 `axi4_dut_missing_wlast_test`、`axi4_dut_premature_wlast_test`。复核 `METHOD_EVIDENCE/negative_tests/run_*.log`。新故障测试选择单独输出和数据库。
6. **实际案例** WSTRB 用 AWADDR=F000，SIZE=0，允许 01 而驱动 FF。Missing WLAST 产生孤立 B，Premature WLAST 产生长为 4、实测 2 的错配。
7. **前后效果** 历史 WLAST 正常对照的 Checker errors 为 0，两个注入各 1。WSTRB 注入的 Checker errors 为 1，UVM_FATAL 为 0。旧任务记录目标 WLAST 条件为 3/3。当前主 VDB 的两种异常组合保留未命中。
8. **验收方法** 检查 `[AXI4_CHK]`、字段和精确计数，并检查各 case 结束握手。UVM_ERROR 先按诊断类型判定。即使 SIM_RC=0 也可能命中预期错误。
9. **注意事项** 故障用例不进入主正向回归人数或 DUT 覆盖分母。SVA 的失败和 Checker 的 UVM_ERROR 是不同观察点。
10. **复用建议** 对 ready/valid 总线用无 LAST、过早 LAST 或无请求的响应作为单故障。先写验收预期再注入。

**旧 AW Hold 和 4KB SVA。** AW Hold 的负向构造是在 AWVALID=1 且 AWREADY=0 的等待周期改变 AWADDR 等载荷，预期由 `a_kvips_aw_hold` 检出。4KB 注入由 `axi4_dut_4kb_sva_negative_test` 构造，历史任务记录 AW/AR 各捕获一次。本次仅引用。检索范围与可用证据见 `REGRESSION_SUMMARY.md`。

## 五、Checker 与 SVA

### 缓存 Early-W 的 strobe，等 AW 到达再校验

1. **适用场景** W 与 AW 可独立握手，Checker 可能先看到完整 W burst。
2. **主要解决的问题** 旧路径缓存 strobe 后仅弹出。AW-first 调到 `check_wstrb_for_beat`，完整 Early-W 路径少一次检查。
3. **可能提升的指标** Checker 检错能力。当前 RAM 只支持 AW 先握手，因此本方法的证据采用独立台架。
4. **原理** W 没有 ID，按顺序匹配最老的 completed W burst 和 AW。AW 携带 ID/ADDR/SIZE/LEN/BURST，再对每个已缓存 beat 按实际 index 使用相同的 lane 函数。
5. **操作步骤** 在 `scripts/early_w_checker_tb.sv` 观察四组序列。分别调用 `run_early_w_checker.sh` 的 before 和 after，用有独立 ready 的端点检查 W 完成早于 AW、AW 在 burst 中途和 AW-first。
6. **实际案例** 两个完整 W burst 先到，AW ID 3/9 后到。ID 3 的 beat1 允许 30，注入 31。另有一笔 partial Early-W 和一笔 AW-first。
7. **前后效果** 两侧各 4 AW、6 W、4 B。合法对照 errors 0→0，注入的目标 Checker errors 0→1，其他错误为 0。
8. **验收方法** 要求精确 `AXI4_CHK`、目标 ID 与地址、实际/允许/非法掩码，检查缓存清空。看 `early_w_*` 下的日志和 `verdict.log`。
9. **注意事项** Checker 不缓存 WDATA，仅保留节拍和 strobe。Monitor 目前只在已有 AW 时采 WDATA/WSTRB，过程式接口 SVA 也默认 AW-first。独立台架仅测试 Checker 并保留这些边界。
10. **复用建议** 在协议允许拆开传输的环境中验证多笔队列和错配控制。先确认各通道实际握手和关联顺序，再复用既有字段检查。

### 用非空成功确认断言参与

1. **适用场景** SVA 编译成功，报表却显示 0 real successes 或只有 vacuous attempts。
2. **主要解决的问题** 使能开关、antecedent 从未成立、断言没有观察到目标输入。
3. **可能提升的指标** Assertion Coverage、相关启动配置 Toggle。
4. **原理** Hold 属性在 VALID && !READY 被采样时立下下一拍稳定义务，KNOWN 属性需通道 VALID 和已知值检测使能。日志的 0 failures 要和真实成功一起看。
5. **操作步骤** 在 `axi4_if_sva.svh` 找 `a_kvips_b_hold` 与 `a_kvips_known_*`，用 BREADY 专项的 `+KVIPS_AXI4_ASSERT_KNOWN`，对照 `asserts.txt` 的 real successes 与 failures。
6. **实际案例** 五个 known 属性先前默认关闭。BREADY 专项报告 BVALID/BID/BRESP 稳定性，波形记录实际等待。
7. **前后效果** 接口 22/28→27/28。B hold 全回归 293→768 个真实成功、0 失败。BREADY 专项贡献 154 个真实成功。
8. **验收方法** 使用 `reports/final/urg/raw/asserts.txt` 和该例的 hold 计数，核对五个 known 通道都有真实成功。
9. **注意事项** 汇总的 UVM 库定义还有 2 个无尝试项，项目断言用 `top` 实例层级解读。预期 SVA 失败应注明属性名、触发时间与唯一注入。
10. **复用建议** 在任意 Valid/Ready 协议写断言时，用独立合法等待样本和可控单故障佐证触发与检错。

## 六、Backpressure 与 Pipeline

### 用实际握手验证 READY 延迟

1. **适用场景** 配置项已打开，但目标 READY 波形与预期不符，或需要检查延迟期间的稳定性。
2. **主要解决的问题** 非流水 `drive_write()` 结束 W 后直接置 BREADY。Delay Test 设置 `master_bready_random` 时未执行随机 BREADY 调度。
3. **可能提升的指标** Hold Assertion 与可达握手向量。本次启用追踪也覆盖诊断 top 的 Line、Condition、Branch。
4. **原理** 使用真正读取该配置的 `pipelined_b_loop()`，等待期间逐拍对 BVALID/BID/BRESP 检查。与同事务、同 seed 的关闭随机 BREADY 对照。
5. **操作步骤** 比对 `axi4_master_driver.svh:548–577` 和 `drive_write`。跑 `axi4_dut_closure_bready_test`，保留 `+DUT_DEBUG +KVIPS_WAVES`，用 `run_bready_control.sh` 做对照。看 `with_random_bready.vcd` 的所有通道握手与等待。
6. **实际案例** 64 写、64 读，每笔 4 beats。旧 Pipeline 的 AW/W/AR/R stall 为 144/32/146/51，B stall 为 0。旧 Delay Test W/B stall 为 39/32，B 的等待来自固定握手时序。
7. **前后效果** BREADY 对照与随机组为 64/64 个 B，stall cycles 0→154，受阻响应 0→30，最长等待 0→19，载荷变化错误 0→0。主回归的 top 增加 21 Line、24 Condition、2 Branch。
8. **验收方法** 在采样沿看 BVALID && !BREADY，持续到 B handshake。核对事件日志、SVA、读数据、VCD。出现连续 low 重新调度时，最长等待可大于单次配置的 4–7 拍。
9. **注意事项** RAM 至多单笔/方向，VIP 配置 2 不会让本 RAM 并行接受 2 笔。WREADY 在首个非末拍后由 DUT 插入低电平，RREADY 由 master 控制。
10. **复用建议** 为各通道设独立等待与完成计数。性能分析区分发起、接收、退休和稳定性。

## 七、Functional Coverage

### 从采样时机到有意义的 Cross

1. **适用场景** 功能组为 0 或覆盖列表有响应、宽度、mask 的长期缺口。
2. **主要解决的问题** 采样未开启、采样时交易尚未完成、交叉中含不适用的组合。
3. **可能提升的指标** Functional Variables、Crosses 及有效 bin 解释。
4. **原理** 写在匹配的 B 返回时采样，读在组包完成时采样。Cross 只保留有规划目标的联合条件，由样本或可达性证明闭环。
5. **操作步骤** 在 `axi4_monitor.svh` 查两处 `cov.sample`，用 `+KVIPS_AXI4_COV=1` 才启动 VCS 采样。对照 `grpinfo.txt` 的 Variable、Cross 和 Element holes。
6. **实际案例** `cp_burst`、`cp_size` 等已有 Coverpoint 按实际事务取值，`cx_burst_size` 验证合法组合。`cx_narrow_strb` 的满字窄写用既有 ignore bin。
7. **前后效果** 初始采集试跑 0/79，开启采样后的正式基线 73/79，这属于测量设置。原 17 项 55/79→统一正常 23 项 73/79，最终仍为 73/79。
8. **验收方法** Variable 与 Cross 分开查 hit/total、bin 名、匹配测试及响应。独立读回或协议检查证明该 bin 来自真实合法事务。
9. **注意事项** 本 RAM 仅有 OKAY/DECERR。Burst 与长度、起始 lane、LOCK 分属现有组，ID 走位、stall、复位、WLAST/RLAST 用日志/断言或独立证据。无意义的全笛卡尔积会稀释目标。
10. **复用建议** 先写覆盖计划与范围，再选择具体 cross。逐 bin 定义在握手哪一拍或哪个 transaction complete 点采样。

## 八、Coverage Debug 与 Closure

### 定位 → 分析 → 排查 → 解决 → 验证

1. **适用场景** 有多份报表和多种缺口，需区分刺激问题与统计问题。
2. **主要解决的问题** 总体百分比掩盖模块边界，错把错误注入、路径未到或静态不可达当成激励不足。
3. **可能提升的指标** 依据缺口选择 Line、Condition、Toggle、Branch、Functional 或 Assertion。
4. **原理** 状态前提和测量口径一起决定实际命中。使用相同 VDB 的筛选子集隔离新增用例带来的影响。
5. **操作步骤** 定位到 `modinfo.txt` 的行/表达式/方向。分析各列子条件与采样沿。排查 VCS flags、scope、constraint、驱动真实分支和参考数据。补上可达缺口的最小激励，最后重跑并匹配相同的统计键与分母。
6. **实际案例** 地址高位未翻转是激励，INCR 默认约束限制 burst，BREADY 随机原来走错 driver mode。功能采样默认关是配置。WREADY 三个向量由 RTL 排除。
7. **前后效果** 原始缺口 493→80，最终 26/26 PASS。Condition +25.81 pp，Toggle +24.09 pp，RAM 分支前后 20/20，接口错误分支仍保留。
8. **验收方法** `COVERAGE_HOLE_INVENTORY.csv` 给出逐点归因，`COVERAGE_HOLE_INVENTORY_CONDITION_VECTORS.csv` 按表达式列出所有已命中及未命中向量。`stage_0` 应复现基线。
9. **注意事项** VCS 的 test location 带数据库路径前缀。先用 `urg -show availabletests` 列出真实标签。评估条件时看工具生成的向量，而非假定任意 N 位表达式都有 2^N 个覆盖项。
10. **复用建议** 用同一工具版本冻住源码、指标集合和正向名单。为每个指标保留“为何变化”和可以重放的证据。

### 用 RTL 不变量审查排除

1. **适用场景** 命中某个向量需要不可同时成立的状态，或 IP 配置缺少某种功能。
2. **主要解决的问题** 误删可达目标、使用失配排除、比较两份不同分母的报告。
3. **可能提升的指标** 有效范围解释及可选报告的分母透明度。
4. **原理** 追踪状态的置位、清除和同周期更新。给出具体不可达条件和所用假设。
5. **操作步骤** 查 `axi4_ram_slave.sv:153–206` 与 `EXCLUSION_REVIEW.md`。运行 `review_exclusions.sh`，检查 `-excl_strict` 日志与逐项生效后的报告。
6. **实际案例** WREADY stall 计数非零时 active=1、WREADY=0 持续到计数清零，旧规则只排 011/101/110。响应 v3 的旧 checksum 被当前模型拒绝。
7. **前后效果** 原始 Condition 52/93→76/93。可选 WREADY 排除视图为 52/90→76/90。功能 v3 两侧均未生效，原始仍为 73/79。
8. **验收方法** 按每条向量的 Excluded 或 Covered 状态检查正误。日志与分母要吻合。未知项保留证据和范围。
9. **注意事项** RTL 逐路径推导依赖当前实例和合法输入约束。修改 RTL、时钟、reset 寄存器或配置之后要重审。
10. **复用建议** 把排除绑定模块、行号、表达式和设计条件。所有项目同时留 raw 和审查后的独立视图。
