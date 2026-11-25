#!/usr/bin/env python3
"""Cycle-based VCD evidence independent from the testbench's checkers."""
import re
from collections import Counter, defaultdict
from pathlib import Path


FIELDS = {
    "aw": ("id", "addr", "len", "size", "burst", "lock"),
    "w": ("data", "strb", "last"),
    "b": ("id", "resp"),
    "ar": ("id", "addr", "len", "size", "burst", "lock"),
    "r": ("id", "data", "resp", "last"),
}
PINS = {"aclk", "areset_n", "kvips_outs_w", "kvips_outs_r",
        "kvips_axi4_assertions_on", "kvips_axi4_excl_checks_on"}
for ch, fields in FIELDS.items():
    PINS.update(ch + field for field in ("valid", "ready", *fields))


def require(ok, message):
    if not ok:
        raise ValueError(message)


def cycles(path):
    scope, codes, current, changes = [], defaultdict(list), {}, {}
    samples = []
    time, header = 0, True

    def finish():
        if changes.get("aclk") == 1 and current.get("aclk") == 0:
            samples.append((time, current.copy()))
        current.update(changes)
        changes.clear()

    with Path(path).open(encoding="utf-8", errors="replace") as file:
        for row in file:
            parts = row.split()
            if not parts:
                continue
            head = parts[0]
            if header:
                if head == "$scope":
                    scope.append(parts[2])
                elif head == "$upscope":
                    scope.pop()
                elif head == "$var":
                    name = parts[4]
                    if (scope == ["top", "axi"] and name in PINS) or (scope == ["top", "dut"] and name == "rd_active"):
                        codes[parts[3]].append(name)
                elif head == "$enddefinitions":
                    names = {name for aliases in codes.values() for name in aliases}
                    require(PINS <= names, f"{path}: missing VCD signals {PINS - names}")
                    header = False
            elif head.startswith("#"):
                finish()
                time = int(head[1:])
            elif head[0] in "bB" and len(parts) == 2:
                digits = head[1:].lower()
                value = int(digits, 2) if re.fullmatch(r"[01]+", digits) else None
                changes.update((name, value) for name in codes.get(parts[1], ()))
            elif head[0] in "01xXzZ":
                value = int(head[0]) if head[0] in "01" else None
                changes.update((name, value) for name in codes.get(head[1:], ()))
    finish()
    require(bool(samples), f"{path}: no clock edges")
    return samples


def epochs(samples):
    active = []
    for row in samples:
        if row[1]["areset_n"] == 1:
            active.append(row)
        elif active:
            yield active
            active = []
    if active:
        yield active


def handshakes(samples, hold_exception=None):
    held, events = {}, defaultdict(list)
    hold_changes = []
    for time, pins in samples:
        require(pins["areset_n"] == 1, f"Unexpected reset at {time}")
        require(pins["kvips_axi4_assertions_on"] == pins["kvips_axi4_excl_checks_on"] == 1,
                f"Checker configuration off at {time}")
        for ch, fields in FIELDS.items():
            valid, ready = pins.get(ch+"valid"), pins.get(ch+"ready")
            payload = tuple(pins.get(ch+field) for field in fields)
            if ch in held and (valid != 1 or payload != held[ch]):
                require(ch == hold_exception and valid == 1, f"{ch} hold violation at {time}")
                hold_changes.append((ch, time, held[ch][1], payload[1]))
            if valid == ready == 1:
                require(None not in payload, f"Unknown {ch} payload at {time}")
                events[ch].append(dict(zip(fields, payload), time=time))
                held.pop(ch, None)
            elif valid == 1 and ready == 0:
                held[ch] = payload
    return events, hold_changes


def counts(events):
    return tuple(len(events.get(ch, ())) for ch in FIELDS)


def check_completed_pair(events, address, id_, data, length):
    beats = length + 1
    require(counts(events) == (1, beats, 1, 1, beats), "Wrong clean handshakes")
    for ch in ("aw", "ar"):
        req = events[ch][0]
        require((req["addr"], req["id"], req["len"], req["size"], req["burst"], req["lock"]) ==
                (address, id_, length, 3, 1, 0), f"Wrong recovery {ch} metadata")
    for ch in ("w", "r"):
        frames = events[ch]
        require([event["last"] for event in frames] == [0]*length + [1], f"Wrong recovery {ch} LAST")
        require(all(event["data"] == data for event in frames), f"Wrong recovery {ch} payload")
    require(all(event["strb"] == 255 for event in events["w"]), "Wrong recovery WSTRB")
    for ch in ("b", "r"):
        require(all((event["id"], event["resp"]) == (id_, 0) for event in events[ch]),
                f"Wrong recovery {ch} response")
    require(events["aw"][0]["time"] < events["w"][0]["time"] <= events["w"][-1]["time"] <
            events["b"][0]["time"] < events["ar"][0]["time"] < events["r"][0]["time"],
            "Wrong clean transactions order")


def check_reset(path, case):
    samples = cycles(path)
    spans = list(epochs(samples))
    require(len(spans) == 2, f"Expected two active epochs in {path}")
    before, after = spans
    reset = [(t, p) for t, p in samples if before[-1][0] < t < after[0][0]]
    require(len(reset) == 2 and all(p["areset_n"] == 0 for _, p in reset), "Expected two sampled reset cycles")
    require(all(reset[-1][1][name] == 0 for name in ("bvalid", "rvalid", "kvips_outs_w", "kvips_outs_r")),
            "Old response/state not cleared after sampled reset")
    old, _ = handshakes(before)
    expected = {"aw": (1, 0, 0, 0, 0), "b": (1, 2, 0, 0, 0), "r": (0, 0, 0, 1, 0)}
    require(counts(old) == expected[case], f"Unexpected pre-reset handshakes: {counts(old)}")
    req = old["ar" if case == "r" else "aw"][0]
    require((req["id"], req["addr"], req["len"], req["size"]) == (7, 0x100, 1, 3), "Wrong aborted request")
    tail = before[-1][1]
    if case == "aw":
        require(tail["kvips_outs_w"] == 1 and tail["bvalid"] == 0, "Missing pending AW")
    if case == "b":
        require((tail["bvalid"], tail["bready"], tail["bid"]) == (1, 0, 7), "Missing stalled B")
        require([beat["last"] for beat in old["w"]] == [0, 1], "Wrong pre-reset WLAST")
    if case == "r":
        require((tail["rvalid"], tail["rready"], tail["rid"], tail["rlast"]) == (1, 0, 7, 0), "Missing stalled R")
    writes, _ = handshakes(after)
    check_completed_pair(writes, 0x200, 7, 0x59ebf00d4bc3027a, 1)
    idle = [p for t, p in after if t < writes["aw"][0]["time"]]
    require(sum(p["bready"] == p["rready"] == 1 for p in idle) >= 3 and
            all(p["bvalid"] == p["rvalid"] == 0 for p in idle), "Old response after reset release")
    return f"{case}: old {counts(old)}, two reset cycles, new {counts(writes)}, reset sampled at {reset[0][0]}"


def check_arlock(path):
    samples = cycles(path)
    events, _ = handshakes([row for row in samples if row[1]["areset_n"] == 1])
    require(counts(events) == (1, 1, 1, 3, 3), "Wrong ARLOCK case handshake counts")
    require(events["aw"][0]["lock"] == 0 and events["w"][0]["strb"] == 255 and
            events["w"][0]["last"] == 1 and events["w"][0]["data"] == 0x0a3e44263141703a,
            "Incorrect ordinary write before reads")
    require((events["b"][0]["resp"], events["b"][0]["id"]) == (0, 6), "Expected RAM write OKAY")
    require([req["lock"] for req in events["ar"]] == [0, 1, 0], "ARLOCK sequence")
    for req, beat in zip(events["ar"], events["r"]):
        require((req["addr"], req["id"], req["size"], req["len"], req["burst"]) ==
                (0x240, 6, 3, 0, 1), "Illegal or incorrect AR request attributes")
        require((beat["id"], beat["resp"], beat["data"], beat["last"]) ==
                (6, 0, 0x0a3e44263141703a, 1), "ARLOCK case readback")
        require(events["b"][0]["time"] < req["time"] < beat["time"], "ARLOCK case ordering")
    values = [p["arlock"] for _, p in samples if p["areset_n"] == 1]
    toggles = Counter(zip(values, values[1:]))
    require(toggles[(0, 1)] and toggles[(1, 0)], "ARLOCK did not toggle in both directions")
    return "ARLOCK handshakes 0→1→0, three verified RAM OKAY responses"


def check_idle(path):
    samples = [row for row in cycles(path) if row[1]["areset_n"] == 1]
    events, _ = handshakes(samples)
    check_completed_pair(events, 0x260, 2, 0xcafe1834baba67e1, 0)
    time = events["ar"][0]["time"]
    idle = [t for t, p in samples if t < time and
            tuple(p.get(s) for s in ("rd_active", "arvalid", "rvalid", "rready")) == (0, 0, 0, 1)]
    require(bool(idle), "No RREADY idle-high 0001")
    return f"Idle 0001 sampled at {idle}, AR at {time}, clean readback after it"
