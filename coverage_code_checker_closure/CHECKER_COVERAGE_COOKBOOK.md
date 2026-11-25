# AXI4 Code Coverage 与 Protocol Checker 实战手册

所有例子来自本轮实跑的 KVIPS 测试。建议先读 [交付索引与复跑命令](README.md)，再从 [最终覆盖率](FINAL_RESULTS.md) 跳到对应测试。VCS 命令使用 `line+cond+tgl+branch+assert`、Seed 1，各 SHA-256 和完整命令由结果目录保存。基线、正向 RAM、独立 Checker 和 VIP 各有独立数据库。

## 1．在途复位

1. **适用场景** AW 接受后还没传 W、写完成在等 B、读响应等 RREADY。
2. **解决问题** 填充待完成上下文后强制切换复位 epoch，验证清理及恢复能否同时成立。
3. **源码** `axi4_if_sva.svh` 402–407，`axi4_dut_code_tests.svh` 的三类 reset 测试，以及 TB 的 `dut_reset_request`。
4. **原理** 先让握手把状态推进真实队列。单一复位 owner 在下降沿控制 ARESETn，保持两个采样上升沿。将复位前后提交给 Monitor 的完成事务分开核对。
5. **步骤** A 只完成 AW。B 发送两拍，末拍 WLAST=1，等待 BVALID 且 BREADY=0。C 接受 AR，保持 RVALID=1 且 RREADY=0。检查过程式队列、类 Checker、Monitor 和覆盖观察状态。复位后先提前拉高两项 READY 排查残留，再复用 ID 7 对不同地址写后读。
6. **VCS 运行** `bash scripts/run_code_checker_closure.sh positive source/final "$replay/reports/positive"`。入口调用三个 `+UVM_TESTNAME=axi4_dut_reset_*_test`。
7. **预期日志** `RESET_CONTEXT` 依次记录 pending、reset_sampled、released、recovered。`CODE_SCOREBOARD` 在恢复前为 0/0、恢复后为 1/1。
8. **URG 检查** 核对 `reports/positive/urg/by_test/axi4_dut_reset_b_test/modinfo.txt` 的 403 和 R 用例的 406/407。检查 `top`、`top.axi` 和 `top.dut` 的复位 1→0。
9. **实测结果** 三例通过。首个复位采样边沿分别在 125、195、145 ns，复位后观察三个 READY 高的采样点，B/R 没有残留。新事务读回 ID、数据、响应和 LAST 均正确。[复位报告](RESET_IN_FLIGHT_RESULTS.md)
10. **注意事项** 用 VCD 的时钟上升沿前状态计数握手。队列元素数量应核对每个 ID，删除队列元素后外层关联数组可能仍有空 key。WSTRB 暂存可以保留已完成写的记录，复位后的暂存必须清零。恢复读回用复位后新写的数据。
11. **复用方法** 在其他总线选定真实在途状态和完成事件，用新旧 ID、目标地址或序号区分两个 epoch；同时检查内部队列、总线响应和参考模型发布。

## 2．W 信道负向注入

1. **适用场景** 需要单独检查 W 帧计数、AW 关联和 WLAST。
2. **解决问题** DUT 的 WREADY 时序会挡住部分故障。把合适的握手完成点移到独立 responder，观察目标检查器实际处理的输入。
3. **源码** `axi4_if_sva.svh` 422–451，`axi4_checker_only_top.sv` 的 `aw`、`w` 和各场景。
4. **原理** Master 拥有 WVALID、数据、WSTRB 和 WLAST，responder 拥有 WREADY。变化在下降沿，上升沿同时为 1 才计一拍。每例由相同配置的接口处理。
5. **步骤** 按下表构造异常。记录故障握手，随后用两拍复位清空所有 ID，再跑一对正常写读。
6. **VCS 运行** `bash scripts/run_code_checker_closure.sh negative source/final "$replay/reports/negative"`。每个场景各启动一次 `simv +SCENARIO=<case>`。
7. **预期日志** 必须匹配表中的完整诊断，且时间对应注入拍。之后应有 `CHECKER_RESET_CLEAR` 与 `CHECKER_RECOVERY_PASS`。
8. **URG 检查** 在 `reports/negative/urg/by_test/<case>/modinfo.txt` 查该表达式的真分支和对应 Line。`asserts.txt` 中这些用例的 SVA 失败为 0。
9. **实测结果** 四例产生 6 条预期诊断。分支见下表，恢复写/读对照全部通过。[负向矩阵](NEGATIVE_TEST_MATRIX.csv)
10. **注意事项** `w_without_aw` 验证当前 AW-first 跟踪。AXI4 允许早到的 W，AXI4 协议能否接受需考虑后续匹配 AW。这里整个故障阶段无 AW。[Arm AMBA AXI 规范 A3.3](https://documentation-service.arm.com/static/602a9df190ee6824a1e02b98)
11. **复用方法** 将约束生成器留给正向测试。故障用例从引脚准确控制一个规则的触发时点，并为设计允许的多错误场景明确计数。

| 场景 | 引脚序列与检查原因 | 精确预期诊断 | 实测及 Branch 行 |
|---|---|---|---|
| `w_without_aw` | 仅 WLAST=1 的 W 握手，AW FIFO 为空 | `W beat seen with no outstanding AW` | 1 条，423 |
| `missing_wlast` | AWLEN=1，WLAST 按 0、0，第二拍到期 | `Missing WLAST on final W beat` | 1 条，431 |
| `premature_wlast` | AWLEN=1，首拍 WLAST=1，递减后还有 1 拍 | `Unexpected WLAST before final W beat` 以及 `WLAST asserted but beats_left != 0 after decrement` | 同拍 2 条，434、442 |
| `w_overflow` | AWLEN=1，传三拍且都无 WLAST；第三拍队列剩余为 0 | `Missing WLAST on final W beat` 后接 `W beat overflow (beats_left==0)` | 不同拍 2 条，428、431 |

## 3．B 信道负向注入

1. **适用场景** BID 与已完成写关联，或普通写收到独占成功。
2. **解决问题** 直接验证完成表查找和 LOCK/RESP 属性组合。RAM 的正常响应路径不会生成这些刺激。
3. **源码** `axi4_if_sva.svh` 455–465，独立 TB 的 `b` 及写恢复任务。
4. **原理** B 握手时查 `kvips_wr_done_lock_q[bid]`。最后一拍 W 后记录 AWLOCK，收到 B 时出队核对。
5. **步骤** `orphan_b` 用不存在的 BID=12 且无 AW/W；`b_exokay_unlocked` 用正常 AWLOCK=0 的合法单拍写，随后发匹配 BID=7、EXOKAY。BREADY 提前为 1。
6. **VCS 运行** `bash scripts/run_code_checker_closure.sh negative source/final "$replay/reports/negative"`。定位对应 `+SCENARIO=orphan_b` 或 `+SCENARIO=b_exokay_unlocked`。
7. **预期日志** 分别为 `B seen with BID having no completed write data` 和 `BRESP=EXOKAY observed for non-exclusive write`。
8. **URG 检查** 在逐例 `modinfo.txt` 检查第 456、461 行的真 Branch。孤立 B 时 465 的计数条件为假。
9. **实测结果** 每例 1 次，复位和完整恢复均通过。对照中 B 与 AW/W 的 ID、时钟和 OKAY 亦完成核对。[逐例结果](NEGATIVE_TEST_MATRIX.csv)
10. **注意事项** 孤立 B 与非法 BRESP 分开测试。前者必须无完成记录，后者必须有完成记录。检查 BRESP 的错误路径不以类 Checker 的 UVM report 为证据。
11. **复用方法** 类似的 Completion/Response 通道可用不同 ID 搜索空表、非空表及元数据不匹配三个目标检查。

## 4．R 信道负向注入

1. **适用场景** 验证 RID 查找、RLAST、读拍数与读独占响应。
2. **解决问题** 确认接口依据对应 ID 的队列与剩余数定位错误。
3. **源码** `axi4_if_sva.svh` 470–502，独立 TB 的 `ar`、`r` 及恢复任务。
4. **原理** AR 握手将 LEN+1 与 LOCK 按 ID 入队。R 握手更新剩余拍数，RLAST 完成则清理该 ID。
5. **步骤** 按表设置 AR 和 R。RREADY=1。每项完成后复位并用正常流复核。
6. **VCS 运行** `bash scripts/run_code_checker_closure.sh negative source/final "$replay/reports/negative"`。逐例 `+SCENARIO=<case>` 命令存于结果目录。
7. **预期日志** 精确匹配下表。EXOKAY 场景冒烟日志要求 `assertions=1 excl=1 known=1`。
8. **URG 检查** 用逐例 `modinfo.txt` 的 478/485/488/491/494 定位。并发计数对照使用它自己的 502 行 Branch。
9. **实测结果** 五例共 6 条预期过程式诊断，均在原始 VCD 对应 R 握手上。复位后各例正常对照通过。[波形核验](WAVEFORM_VERIFIED.txt)
10. **注意事项** R overflow 的额外一拍用 RLAST=0，避免再引入提前 LAST。在合法并发读对照中，采样队列和计数两个独立状态，检查同拍 AR 与 RLAST 的计数竞争。
11. **复用方法** 将响应 ID、预期拍数和可变返回属性分层验证，先在干净对照里确认每个输入真正走到对应处理队列。

| 场景 | 引脚序列与检查原因 | 精确预期诊断 | 实测及 Branch 行 |
|---|---|---|---|
| `orphan_r` | 无 AR，直接对未使用 RID=12 从端发 R | `R beat seen with no outstanding AR for RID` | 1 条，478 |
| `missing_rlast` | ARLEN=1，RLAST 按 0、0，下一个期望终拍未标注 | `Missing RLAST on final R beat` | 1 条，485 |
| `premature_rlast` | ARLEN=1，第一拍 RLAST=1 | `Unexpected RLAST before final R beat` | 1 条，488 |
| `r_overflow` | ARLEN=1，三个 R 握手，RLAST 全为 0 | `Missing RLAST on final R beat` 后接 `R beat overflow (beats_left==0)` | 2 条，485、494 |
| `r_exokay_unlocked` | ARLOCK=0，正确 RID 和 RLAST，RRESP=EXOKAY | `RRESP=EXOKAY observed for non-exclusive read` | 1 条，491 |

## 5．SVA 的尝试、真实成功和失败

1. **适用场景** 需要知道一个属性被采样、实际成立还是检出错误。
2. **解决问题** 将 vacuous 成功、nonvacuous 成功与真正的属性失败对应到明确激励。
3. **源码** `axi4_if_sva.svh` 的 `kvips_p_aw_hold`、`a_kvips_aw_hold`、AW/AR exclusive restrictions 及启动开关。
4. **原理** `A |=> B` 只有 A 采样成立后才检查下一周期的 B。`asserts.txt` 提供 ATTEMPTS、REAL SUCCESSES 和 FAILURES。过程式 `$error` 没有这组属性计数。
5. **步骤** 使能检查。保持 AWVALID=1、AWREADY=0，将地址从 `0x100` 改为 `0x108`，保持新地址至 AW 握手。保留后续采样周期再复位。
6. **VCS 运行** `bash scripts/run_code_checker_closure.sh negative source/final "$replay/reports/negative"`。`aw_hold_violation` 用相同接口、相同 SVA。
7. **预期日志** `a_kvips_aw_hold: started at ... failed at ...` 恰好 1 次，过程式 `KVIPS_AXI4_ASSERT:` 0 条。
8. **URG 检查** 查看 `urg/by_test/aw_hold_violation/asserts.txt` 的该属性条目，同步检查其余属性失败为 0。
9. **实测结果** 真实成功 1、失败 1，恢复通过。RAM 正向 27/28 属性有非空成功，Checker LOCK 两项各 1 次非空成功。[属性报告](ASSERTION_RESULTS.md)
10. **注意事项** 时钟、`disable iff`、逻辑采样和复位的时序都会影响 FAILURES。先确认前件和负向载荷才宣布检错。
11. **复用方法** 给关键属性各准备刺激成功和刺激失败的对照，以相同属性定义、开关及 VCD 确认精确结果。

## 6．合法属性、空闲 READY 与 Toggle

1. **适用场景** 稳态测试很少触发属性、静态信号或特定组合向量。
2. **解决问题** 验证真实 0→1→0，与覆盖表中单向 Toggle 和 Nonvacuous 匹配。
3. **源码** `axi4_if_sva.svh` 292–329；`top.sv` 的 DUT_DEBUG 状态打印；RAM WREADY 和 RVALID 同步逻辑。
4. **原理** 相同实例的同一仿真内需要信号发生边沿。合法 SIZE[2] 恒为 0。RREADY 可在 AR/R 均空闲时为 1。
5. **步骤** RAM 先写满数据，发送普通读、锁定读、普通读。独立台架在两次普通读写之间插入合法 LOCK/EXOKAY 配对。RREADY 场景空闲高三拍后发读。复位场景用有效高到低边沿补足 ARESETn。
6. **VCS 运行** 分别使用 `positive`、`negative` 模式。RREADY 用例带 `+DUT_DEBUG`，两组都有 `+KVIPS_WAVES` 的定向记录。
7. **预期日志** `CODE_SCOREBOARD` 错误均为 0。空闲 RREADY 打印含 `arv=0 rd_active=0 rv=0 rr=1`。独占开关为 1。
8. **URG 检查** 对应单测的 Toggle 0→1/1→0，核对 RREADY 向量 0001 与 SVA 的 REAL SUCCESSES。保留 0010、SIZE[2] 等未命中记录。
9. **实测结果** RAM 补 ARLOCK 双向、三处 ARESETn 下降沿与一个 Condition。Checker 独立控制验证 AWLOCK、ARLOCK 的双向与成功属性；VIP 维持 EXOKAY 语义测试。[范围审查](EXCLUSION_REVIEW.md)
10. **注意事项** RAM 的锁定读按普通 OKAY 返回。独占成功能力由支持 EXOKAY 的台架证明。DUT 锁定写探针的失配属于独立证据。
11. **复用方法** 针对每个低覆盖属性构造先验合法值、目标值、恢复值。在读写握手上检查这些值，然后验证它们有可观测的行为结果。

## 7．覆盖率收敛与证据链

1. **适用场景** 同时维护 DUT 正向、协议负向和 VIP 证据。
2. **解决问题** 区分旧点增量、统计范围变化及异常激励的贡献。
3. **源码** `scripts/review_coverage.py`、`scripts/report_test_details.sh`、`scripts/verify_results.py`。
4. **原理** URG 的分母、代码位置、向量和方向是比较单位。同一模型的 VDB 子集可按真实 test path 重生成报告。
5. **步骤** 固定提交和测试表，先重跑基线。从 `modinfo.txt`、`asserts.txt` 定位每项缺口。用源码和状态机分析可达性，设计正向或隔离的注入。跑仿真，核验日志、VCD 和 URG。
6. **VCS 运行** 四个模式见 [复跑入口](README.md)。`commands.sh` 列出基线、最终及阶段的原始参数。
7. **预期日志** 旧 30 项和新增 5 项正向通过，负向 12 项精确错误与复位恢复对照，VIP 36 项通过。
8. **URG 检查** 首先 `urg -full64 -dir <coverage.vdb> -show availabletests`，用列表中的完整测试路径生成 `-tests` 输入。`-show ratios -cond ids` 展开计数与向量。按照原始三模块分母验证。
9. **实测结果** 87.26% → 87.98%，正向 Branch 44/58。独立的 11 项注入使接口有 33/34 Branch 命中，加入对照后 34/34。原始 73/79、增强 185/185 和 VIP 79/79 保持。[最终报告](FINAL_RESULTS.md)
10. **注意事项** 新增 Testbench Line 计入最终分母。两种 `top` 的 VDB 层级内容不同。结论引用自己范围内的证据，外部排除保持为 0。
11. **复用方法** 将每个缺口追溯到源码、触发样本、用例、波形和日志签名。复核同一 VDB 的旧用例切片，剩余项注明可达范围和设计依据。
