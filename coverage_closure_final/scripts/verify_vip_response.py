#!/usr/bin/env python3
"""Check regression outcomes, URG bin attribution, and sampled AXI handshakes."""
import re
import sys
from collections import defaultdict
from pathlib import Path


CASES = (
    "slverr_write", "slverr_read", "exclusive_basic", "exclusive_fail",
    "error_rate", "sideband_coverage",
)
CHANNELS = {
    "aw": ("id", "addr", "len", "size", "burst", "lock", "cache", "prot", "region", "qos"),
    "w": ("data", "strb", "last"),
    "b": ("id", "resp"),
    "ar": ("id", "addr", "len", "size", "burst", "lock", "cache", "prot", "region", "qos"),
    "r": ("id", "resp", "data", "last"),
}
SB_FIELDS = ("enable", "wr_txns", "wr_err", "rd_txns", "rd_mismatch_beats", "rd_uninit_warn_beats")
CHK_FIELDS = ("AW", "W", "B", "AR", "R", "errors", "sideband_errors")


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


def test_name(case):
    return "axi4_b2b_" + case + "_test"


def require(ok, message):
    if not ok:
        raise ValueError(message)


def values(line, fields):
    return tuple(int(re.search(r"\b" + field + r"=(\d+)\b", line).group(1)) for field in fields)


def check_regression(run, expected_total):
    tests = read(run / "tests.list").splitlines()
    require(len(tests) == len(set(tests)) == expected_total, f"Unexpected list for {run}")
    counts = {}
    for test in tests:
        log = read(run / "tests" / (test + ".log"))
        rc = read(run / "tests" / (test + ".rc")).strip()
        require(rc == "0" and f"[RNTST] Running test {test}..." in log, f"Unexpected simulator exit {test}")
        require(re.findall(r"^UVM_(?:ERROR|FATAL)\s*:\s*(\d+)\s*$", log, re.M) == ["0", "0"],
                f"Unexpected UVM error in {test}")
        require(not re.search(r"(?m)^\s*(?:Error[:\-]|Fatal[:\-])", log),
                f"Unexpected simulator or assertion error in {test}")
        checker = values(re.search(r"^.*Channel checker summary:.*$", log, re.M).group(), CHK_FIELDS)
        scoreboard = values(re.search(r"^.*AXI4 SB summary:.*$", log, re.M).group(), SB_FIELDS)
        aw, w, b, ar, r, errors, sideband_errors = checker
        sb_en, wr, wr_err, rd, mismatches, uninit = scoreboard
        require((errors, sideband_errors, sb_en, mismatches) == (0, 0, 1, 0), f"Checker/SB failure {test}")
        require(b == wr and rd <= r, f"Bus vs monitor count discrepancy in {test}")
        if test == test_name("timeout_recovery"):
            require("Handshake timeout on AW; returning timeout-aborted item" in log and
                    (aw, w, b, ar, r) == (0, 0, 0, 0, 0), "Missing expected timeout recovery evidence")
        else:
            require(aw + ar > 0 and b + r > 0, f"No completed traffic in {test}")
        if test in (test_name("slverr_read"), test_name("slverr_write"), test_name("sideband_coverage")):
            require(" [VIP_RESP_CHECK] " in log and uninit == 0, f"Missing directed completion {test}")
        counts[test] = (aw, w, b, ar, r)
        print(f"{run.name:8} PASS {test} AW/W/B/AR/R={aw}/{w}/{b}/{ar}/{r} "
              f"WR/ERR/RD={wr}/{wr_err}/{rd} uninit={uninit}")
    return counts


def waveform(path):
    """Sample pre-edge signal values on ACLK rising edges from top.axi."""
    fields = {"aclk", "areset_n"}
    for channel, payload in CHANNELS.items():
        fields.update(channel + field for field in ("valid", "ready", *payload))
    scope, codes, values_now, updates = [], {}, {}, {}
    result = defaultdict(list)
    time = 0

    def sample():
        if (updates.get("aclk") == "1" and values_now.get("aclk") == "0"
                and values_now.get("areset_n") == "1"):
            for channel, payload in CHANNELS.items():
                if (values_now.get(channel+"valid"), values_now.get(channel+"ready")) != ("1", "1"):
                    continue
                event = {"time": time}
                for field in payload:
                    value = values_now.get(channel + field, "x")
                    event[field] = int(value, 2) if re.fullmatch(r"[01]+", value) else None
                    require(event[field] is not None or (channel == "r" and field == "data"),
                            f"Unknown {channel}{field} at {time} in {path}")
                result[channel].append(event)
        values_now.update(updates)
        updates.clear()

    header = True
    with path.open(encoding="utf-8", errors="replace") as trace:
        for row in trace:
            parts = row.split()
            if not parts:
                continue
            head = parts[0]
            if header:
                if head == "$scope":
                    scope.append(parts[2])
                elif head == "$upscope":
                    scope.pop()
                elif head == "$var" and scope == ["top", "axi"] and parts[4] in fields:
                    codes[parts[3]] = parts[4]
                elif head == "$enddefinitions":
                    missing = fields - set(codes.values())
                    require(not missing, f"Incomplete AXI wave {path}: {', '.join(sorted(missing))}")
                    header = False
            elif head.startswith("#"):
                sample()
                time = int(head[1:])
            elif head[0] in "bB" and len(parts) == 2 and parts[1] in codes:
                updates[codes[parts[1]]] = head[1:].lower()
            elif head[0] in "01xXzZ" and head[1:] in codes:
                updates[codes[head[1:]]] = head[0].lower()
    sample()
    return result


def check_pairs(events, test):
    require(len(events["aw"]) == len(events["b"]), f"Unpaired AW/B in {test}")
    write_at = 0
    for aw, b in zip(events["aw"], events["b"]):
        beats = aw["len"]+1
        frames = events["w"][write_at:write_at+beats]
        require(len(frames) == beats and [event["last"] for event in frames] == [0]*(beats-1)+[1] and
                aw["time"] <= frames[0]["time"] <= frames[-1]["time"] <= b["time"] and b["id"] == aw["id"],
                f"Wrong W beat framing or BID in {test}")
        write_at += beats
    require(write_at == len(events["w"]), f"Extra W beat in {test}")
    read_at = 0
    for ar in events["ar"]:
        beats = ar["len"]+1
        frames = events["r"][read_at:read_at+beats]
        require(len(frames) == beats and [event["last"] for event in frames] == [0]*(beats-1)+[1] and
                ar["time"] <= frames[0]["time"] and all(event["id"] == ar["id"] for event in frames),
                f"Wrong R beat framing or RID in {test}")
        read_at += beats
    require(read_at == len(events["r"]), f"Extra R beat in {test}")


def check_cases(final, counts):
    for case in CASES:
        test = test_name(case)
        events = waveform(final / "tests" / (test + ".vcd"))
        require(tuple(len(events[ch]) for ch in CHANNELS) == counts[test], f"Wave/checker count mismatch {test}")
        check_pairs(events, test)
        aw, w, b, ar, r = (events[ch] for ch in CHANNELS)
        bresp = [event["resp"] for event in b]
        rresp = [event["resp"] for event in r]
        if case == "slverr_write":
            sentinel = 0x13579BDF2468ACE0
            require(bresp == [0, 2] and rresp == [0, 0] and
                    all(event["addr"] == 0x4000 and event["lock"] == 0 for event in aw+ar) and
                    [event["data"] for event in w] == [sentinel, sentinel ^ 0xFFFFFFFFFFFFFFFF] and
                    all(event["strb"] == 0xFF for event in w) and
                    [event["data"] for event in r] == [sentinel, sentinel] and
                    b[0]["time"] < r[0]["time"] < aw[1]["time"] < b[1]["time"] < ar[1]["time"],
                    "SLVERR write changed data or completed out of order")
        if case == "slverr_read":
            require(bresp == [0] and rresp == [2]*4 and len(ar) == 1 and
                    ar[0]["addr"] == 0x5000 and ar[0]["len"] == 3 and ar[0]["size"] == 3 and
                    ar[0]["id"] == 0xB and ar[0]["lock"] == 0,
                    "SLVERR read must complete four beats at ID B")
        if case in ("exclusive_basic", "exclusive_fail"):
            success = case == "exclusive_basic"
            require(bresp == ([0, 1] if success else [0, 0, 0]) and rresp == [1, 0] and
                    [event["lock"] for event in aw] == ([0, 1] if success else [0, 0, 1]) and
                    [event["lock"] for event in ar] == [1, 0], "Exclusive response/LOCK mismatch")
            require(all(aw[-1][field] == ar[0][field] for field in CHANNELS["ar"]) and
                    aw[-1]["len"] == 0 and aw[-1]["addr"] % (1 << aw[-1]["size"]) == 0 and
                    b[0]["time"] < r[0]["time"] < aw[-1]["time"] < b[-1]["time"] < ar[1]["time"] and
                    r[0]["data"] == w[0]["data"], "Exclusive address tuple or reservation ordering mismatch")
            if not success:
                require(r[0]["time"] < aw[1]["time"] < b[1]["time"] < aw[-1]["time"] and
                        aw[1]["addr"] == ar[0]["addr"] and w[-1]["data"] != w[1]["data"], "Missing interference")
            require(r[-1]["data"] == (w[-1] if success else w[1])["data"], "Exclusive readback mismatch")
        if case == "error_rate":
            require(bresp == [2] and rresp == [3], "Existing rate-based write SLVERR/read DECERR was lost")
        if case == "sideband_coverage":
            require(bresp == [0] and rresp == [0]*6 and
                    [event["prot"] for event in ar] == [1, 2, 4, 5, 6, 7] and
                    [event["qos"] for event in ar] == [4, 12, 15]*2 and
                    all(event["cache"] == event["region"] == 15 for event in ar) and
                    all(event["data"] == 0x7654321089ABCDEF for event in r),
                    "Sideband combinations did not complete with expected data")
        print(f"\nVCD PASS {test} B={bresp} R={rresp}")
        for channel, event in sorted(((ch, e) for ch in CHANNELS for e in events[ch]),
                                     key=lambda pair: pair[1]["time"]):
            data = " ".join(f"{key}={value:#x}" if value is not None else f"{key}=X"
                            for key, value in event.items() if key != "time")
            print(f"{event['time']:7} {channel.upper():2} {data}")


def coverage_summary(report):
    group = read(report / "grpinfo.txt")
    require(re.search(r"(?m)^1 Instances?:", group), f"Unexpected monitor instance count in {report}")
    group = group.split("\nGroup Instance : ", 1)[0]
    ratios = {}
    for metric in ("Variables", "Crosses"):
        total, miss, hits = map(int, re.search(r"(?m)^" + metric + r"\s+(\d+)\s+(\d+)\s+(\d+)", group).groups())
        require(miss + hits == total, f"Inconsistent totals in {report}")
        ratios[metric] = (hits, total)
    return group, (ratios["Variables"], ratios["Crosses"])


def bin_count(group, kind, point, row):
    block = group.split(f"Summary for {kind} {point}\n", 1)[1].split("Summary for ", 1)[0]
    match = re.search(r"(?m)^" + row + r"\s+(\d+)\s+1\s+([^\n]*)$", block)
    require(match is not None, f"Missing URG row {point}/{row}")
    return int(match[1]), match[2]


def test_mapping(report):
    return dict(re.findall(r"(?m)^(T\d+)\s+\S*/(axi4_b2b(?:_\w+)?_test)\s+", read(report / "tests.txt")))


def check_urg(base, final, ram, counts):
    raw = final / "urg/functional"
    _, baseline = coverage_summary(base / "urg/functional")
    group, result = coverage_summary(raw)
    _, inherited = coverage_summary(final / "urg/attribution/inherited")
    _, responses = coverage_summary(final / "urg/attribution/responses")
    _, ram_result = coverage_summary(ram / "urg/raw")
    require(baseline == inherited == ((41, 52), (26, 27)), "VIP baseline/slice mismatch")
    require(responses == ((41, 52), (27, 27)) and result == ((52, 52), (27, 27)),
            "Unexpected response/sideband coverage")
    require(ram_result == ((50, 52), (23, 27)), "RAM distribution changed")
    require(re.search(r"(?m)^PASS=26 FAIL=0 TOTAL=26$", read(ram / "regression-verdict.log")),
            "RAM regression did not pass")
    require(re.search(rf"(?m)^Number of tests: {len(counts)}$", read(raw / "dashboard.txt")),
            "URG test count mismatch")
    for run in (base, final):
        assertions = read(run / "urg/assertions/asserts.txt")
        require(re.search(r"(?m)^Failure\s+0\b", assertions), f"SVA failure in {run.name}")
    mapping = test_mapping(raw)
    baseline_report = base / "urg/functional"
    base_group, _ = coverage_summary(baseline_report)
    baseline_mapping = test_mapping(baseline_report)
    bins = [("Variable", "cp_prot", f"vals_{v}", "sideband_coverage") for v in (1, 2, 4, 5, 6, 7)]
    bins += [("Variable", "cp_qos", bin_name, "sideband_coverage")
             for bin_name in ("qos4_11", "qos12_14", "qos15")]
    bins += [("Variable", "cp_cache", "cF", "sideband_coverage"),
             ("Variable", "cp_region", "r15", "sideband_coverage"),
             ("Cross", "cx_write_resp", r"\[?auto\[0\]\]?\s+\[?slverr\]?", "slverr_read")]
    print("\nNew bins (URG count before -> after, named test from report)")
    for kind, point, row, case in bins:
        before, _ = bin_count(base_group, kind, point, row)
        after, row_tests = bin_count(group, kind, point, row)
        contributors = [mapping.get(label) for label in re.findall(r"\bT\d+\b", row_tests)]
        require(before == 0 and after > 0 and test_name(case) in contributors,
                f"Unproven hit {point}/{row}: {contributors}")
        bin_name = "read x SLVERR" if kind == "Cross" else row
        print(f"{point} {bin_name}: {before} -> {after}, {test_name(case)}")

    print("\nResponse cross control bins (sample counts before -> after)")
    for direction, response, before_count, after_count, test in (
        (1, "slverr", 1, 2, "error_rate"),
        (0, "exokay", 3, 3, "exclusive_basic"),
        (1, "exokay", 1, 1, "exclusive_basic"),
    ):
        row = rf"auto\[{direction}\]\s+{response}"
        before, before_tests = bin_count(base_group, "Cross", "cx_write_resp", row)
        after, after_tests = bin_count(group, "Cross", "cx_write_resp", row)
        require((before, after) == (before_count, after_count), f"Response bin count mismatch: {row}")
        require(test_name(test) in [baseline_mapping.get(label) for label in re.findall(r"\bT\d+\b", before_tests)]
                and test_name(test) in [mapping.get(label) for label in re.findall(r"\bT\d+\b", after_tests)],
                f"Missing inherited test source for {row}")
        if response == "slverr":
            require(test_name("slverr_write") in [mapping.get(label) for label in re.findall(r"\bT\d+\b", after_tests)],
                    "Missing address-scoped write in URG")
        print(f"{'write' if direction else 'read'} x {response.upper()}: {before} -> {after}")


if __name__ == "__main__":
    base, final, ram = map(Path, sys.argv[1:])
    previous = check_regression(base, 33)
    final_counts = check_regression(final, 36)
    require(all(final_counts.get(test) == counts for test, counts in previous.items()),
            "An inherited test changed handshake counts")
    check_cases(final, final_counts)
    check_urg(base, final, ram, final_counts)
    print("\nVERIFIED VIP 33/33 -> 36/36, 67/79 -> 79/79; separate RAM 26/26, 73/79")
