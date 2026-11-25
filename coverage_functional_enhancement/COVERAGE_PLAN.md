# RAM Enhanced Functional Coverage 固定计划

此口径在增强基线编译前确定。新增 `cov_ram_enhanced` 仅由 RAM Testbench 在 `+DUT_FCOV_EXT=1` 下建立。总线宽度 64 位，限定原 RAM 的 AW-first 测试路径。原 `cov` 单独保留 79 个 bin。

| 功能 | Coverpoint （有效 bin） | Cross （有效 bin） | 定向验收 |
|---|---|---|---|
| A. Burst × Length | `cp_burst`（3）、`cp_len`（6） | `cx_burst_len`（15） | 依序读写所列长度。使用真实地址、长度、拍数与 LAST 核验，同页内读回 |
| B. SIZE × Start Lane | `cp_size`（4）、`cp_start_lane`（8） | `cx_size_start_lane`（32） | 每个组合用单拍 INCR 验证读写。不同总线字预填，再用该窄写掩码及全字读回检查 |
| C. 逐拍 WSTRB | `cp_w_pos`（4）、`cp_w_class`（4） | `cx_w_pos_class`（16）、`cx_size_w_class`（13） | 非零预填，改变每拍的合法 strobe。全字读回验证保留与更新 |
| D. 逐拍 RRESP | `cp_r_pos`（4）、`cp_rresp_beat`（2） | `cx_rresp_pos`（8） | 映射内读 OKAY，映射外读 DECERR。逐拍校验 RID、响应、数据和 RLAST |
| E. 实际反压 | `cp_channel`（5）、`cp_stall`（4）、`cp_response_channel`（2）、`cp_response_length`（2） | `cx_channel_stall`（19）、`cx_response_stall`（24）、`cx_response_stall_length`（10） | 通过实际握手记录五通道等待。B/R 用三种 burst 和四档停顿。B/R 的非零停顿再检验单拍与多拍 |
| 合计 | **12 个 coverpoint，48 个 bin** | **8 个 cross，137 个 bin** | **185 个有效 bin** |

长度 coverpoint 以 1、2、4、8、16、256 六个检查点为范围。其他合法长度仍能用于 W/R 与停顿覆盖。`cp_burst` 和 `cp_size` 分别与响应和逐拍分析共用，cross 的 `iff` 约束事件类型。

| Burst | 1 | 2 | 4 | 8 | 16 | 256 |
|---|---|---|---|---|---|---|
| FIXED | ✓ | ✓ | ✓ | ✓ | ✓ | 协议上限 16 |
| INCR | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| WRAP | 非法 | ✓ | ✓ | ✓ | ✓ | 合法值仅 2/4/8/16 |

表中为每个 SIZE × Start Lane 组合首拍的合法 WSTRB 掩码（十六进制）。验证使用单拍 INCR。WRAP 另外受对齐约束。

| SIZE / Start Lane | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 0 / 1 B | 01 | 02 | 04 | 08 | 10 | 20 | 40 | 80 |
| 1 / 2 B | 03 | 02 | 0C | 08 | 30 | 20 | C0 | 80 |
| 2 / 4 B | 0F | 0E | 0C | 08 | F0 | E0 | C0 | 80 |
| 3 / 8 B | FF | FE | FC | F8 | F0 | E0 | C0 | 80 |

令 `S=2**SIZE`、`L=ADDR%8`，首拍合法 lane 为 `L` 至 `floor(L/S)*S+S-1`。收到实际 W Beat 后先判掩码越界，再依次判 Zero、All Legal、Single、Partial。因此只有一条合法 lane 时，唯一使能属于 All Legal。位置分类为 Single（总长度 1）或 First/Middle/Last。

停顿档为 0、1–2、3–5、6 以上个采样周期。AW/AR 在上一笔阻塞时可呈现任意档。W 在 AW 之后仅由 RTL 首个非末 beat 引起最多三拍等待，延迟呈现第二拍可取 1–2 或 0。B、R 的长短停顿均可由 Master 控制。单拍 / 多拍只与 B/R 非零停顿相交。

九个结构性忽略组合在源码预先定义。它们是 FIXED×256、WRAP×1/256、SIZE0×Single/Partial、SIZE1×Partial、AW-first W×Long、B/R 的 WRAP×Single。详见 `EXCLUSION_REVIEW.md`。RRESP 变量从设计起只定义本 DUT 支持的 OKAY、DECERR。无外部 URG exclusion。
