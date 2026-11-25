"""Decode real top.axi VCD handshakes independently of Monitor and covergroups."""
import re
from collections import Counter, defaultdict


AW, W, B, AR, R = range(5)
ADDRESS_FIELDS = ("id", "addr", "len", "size", "burst", "lock", "cache", "prot", "qos", "region", "user")
FIELDS = {"aw": ADDRESS_FIELDS, "w": ("data", "strb", "last", "user"), "b": ("id", "resp", "user"),
          "ar": ADDRESS_FIELDS, "r": ("id", "data", "resp", "last", "user")}
CHANNELS = list(FIELDS)


def check(condition, reason):
    if not condition:
        raise ValueError(reason)


def handshakes(path):
    wanted = {"aclk", "areset_n"}
    for channel, fields in FIELDS.items():
        wanted.update(channel + f for f in ("valid", "ready", *fields))
    scope, codes, now, changes = [], defaultdict(list), {}, {}
    events, held, cycles = defaultdict(list), {}, Counter()
    time = 0

    def finish_timepoint():
        if changes.get("aclk") == "1" and now.get("aclk") == "0":
            if now.get("areset_n") != "1":
                held.clear()
                cycles.clear()
            else:
                for channel, fields in FIELDS.items():
                    valid, ready = now.get(channel+"valid"), now.get(channel+"ready")
                    pins = tuple(now.get(channel+f, "x") for f in fields)
                    if channel in held:
                        check(valid == "1" and held[channel] == pins,
                              f"{path}: {channel} payload changed while stalled at {time}")
                    if valid == "1" and ready == "0":
                        cycles[channel] += 1
                        held[channel] = pins
                    elif valid == "1" and ready == "1":
                        check(all(re.fullmatch(r"[01]+", p) for p in pins),
                              f"{path}: unknown {channel} payload at {time}")
                        event = dict(zip(fields, (int(p, 2) for p in pins)))
                        event.update(time=time, wait=cycles.pop(channel, 0))
                        events[channel].append(event)
                        held.pop(channel, None)
        now.update(changes)
        changes.clear()

    in_header = True
    with path.open(encoding="utf-8", errors="replace") as source:
        for line in source:
            parts = line.split()
            if not parts:
                continue
            head = parts[0]
            if in_header:
                if head == "$scope":
                    scope.append(parts[2])
                elif head == "$upscope":
                    scope.pop()
                elif head == "$var" and scope == ["top", "axi"] and parts[4] in wanted:
                    codes[parts[3]].append(parts[4])
                elif head == "$enddefinitions":
                    check(wanted == {name for names in codes.values() for name in names},
                          f"Incomplete interface signals in {path}")
                    in_header = False
            elif head.startswith("#"):
                finish_timepoint()
                time = int(head[1:])
            elif head[0] in "bB" and len(parts) == 2:
                changes.update((name, head[1:].lower()) for name in codes.get(parts[1], ()))
            elif head[0] in "01xXzZ":
                changes.update((name, head[0].lower()) for name in codes.get(head[1:], ()))
    finish_timepoint()
    check(not held, f"{path}: unfinished held payload")
    return events


def address(req, index):
    start, burst, size, length = (req[k] for k in ("addr", "burst", "size", "len"))
    stride = 1 << size
    aligned = start & -stride
    check(size <= 3 and burst <= 2, "Illegal AxSIZE or AxBURST")
    if burst == 0:
        check(length < 16, "Illegal FIXED length")
        addr = start
    elif burst == 1:
        addr = start if index == 0 else aligned + index*stride
    else:
        check(start == aligned and length in (1, 3, 7, 15), "Illegal WRAP request")
        span = (length+1)*stride
        base = start & -span
        addr = base + ((start - base + index*stride) % span)
    final_byte = (addr & -stride) + stride - 1
    check(start >> 12 == addr >> 12 == final_byte >> 12, "Observed 4 KiB crossing")
    return addr


def sample(req, kind, pos=0, strobe=0, resp=0, channel=0, wait=0):
    stall = 0 if wait == 0 else (1 if wait <= 2 else (2 if wait <= 5 else 3))
    return (kind, req["burst"], req["len"], req["size"], req["addr"] % 8, pos,
            strobe, resp, channel, stall, int(req["len"] != 0))


def wave_samples(path):
    events = handshakes(path)
    samples, beat_timeline = [], []
    for is_write, addr_ch, data_ch in ((True, "aw", "w"), (False, "ar", "r")):
        offset = 0
        if is_write:
            check(len(events["b"]) == len(events[addr_ch]), "Mismatch of AW/B counts")
        for txn_idx, req in enumerate(events[addr_ch]):
            length = req["len"] + 1
            frames = events[data_ch][offset:offset+length]
            check(len(frames) == length, "Truncated burst")
            offset += length
            samples.append(sample(req, 0))
            samples.append(sample(req, 3, channel=AW if is_write else AR, wait=req["wait"]))
            for idx, beat in enumerate(frames):
                check(beat["time"] >= req["time"] and beat["last"] == int(idx == length-1),
                      "Wrong beat time or LAST")
                position = 0 if length == 1 else (1 if idx == 0 else (3 if idx == length-1 else 2))
                beat_addr = address(req, idx)
                if is_write:
                    stride = 1 << req["size"]
                    low = beat_addr % 8
                    high = (low & -stride) + stride
                    legal = (1 << high) - (1 << low)
                    mask = beat["strb"]
                    check(mask & ~legal == 0, "Observed an illegal strobe")
                    classification = 0 if mask == 0 else (3 if mask == legal else (1 if mask.bit_count() == 1 else 2))
                    samples.append(sample(req, 1, pos=position, strobe=classification))
                else:
                    check(beat["id"] == req["id"], "RID mismatch")
                    samples.append(sample(req, 2, pos=position, resp=beat["resp"]))
                samples.append(sample(req, 3, channel=W if is_write else R, wait=beat["wait"]))
                beat_timeline.append((beat["time"], is_write, beat_addr, beat))
            if is_write:
                b = events["b"][txn_idx]
                check(b["time"] >= frames[-1]["time"] and b["id"] == req["id"] and b["resp"] == 0,
                      "BID, response, or completion ordering mismatch")
                samples.append(sample(req, 3, channel=B, wait=b["wait"]))
        check(offset == len(events[data_ch]), f"Unpaired extra {data_ch.upper()} beats")

    memory = {}
    for _, is_write, addr, beat in sorted(beat_timeline, key=lambda e: (e[0], e[1])):
        base = addr & ~7
        if is_write:
            check(base < 0x10000, "Waveform checks expect writes in RAM")
            old = memory.get(base, 0)
            for byte in range(8):
                if beat["strb"] & (1 << byte):
                    mask = 0xff << (8*byte)
                    old = (old & ~mask) | (beat["data"] & mask)
            memory[base] = old
        else:
            mapped = base < 0x10000
            check(beat["resp"] == (0 if mapped else 3) and
                  beat["data"] == (memory.get(base, 0) if mapped else 0),
                  f"VCD data or response disagrees with observed writes at {addr:#x}")

    waits = {ch: dict(sorted(Counter(beat["wait"] for beat in events[ch]).items())) for ch in CHANNELS}
    result = (f"AW/W/B/AR/R={'/'.join(str(len(events[ch])) for ch in CHANNELS)} "
              f"stall_cycles_to_count={waits} read_responses={dict(Counter(r['resp'] for r in events['r']))}")
    return samples, result
