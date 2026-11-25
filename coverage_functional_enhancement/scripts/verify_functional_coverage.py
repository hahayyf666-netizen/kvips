#!/usr/bin/env python3
"""Reconcile completed-frame sample logs, URG counts, and independent VCD evidence."""
import csv
import importlib.util
import itertools
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

from verify_fc_waveforms import wave_samples


BURST = {0: "fixed_b", 1: "incr_b", 2: "wrap_b"}
LENGTH = {n-1: f"beats_{n}" for n in (1, 2, 4, 8, 16, 256)}
SIZE = {n: f"size_{n}" for n in range(4)}
LANE = {n: f"lane_{n}" for n in range(8)}
POSITION = dict(enumerate(("single_beat", "first", "middle", "last_beat")))
STRB = dict(enumerate(("zero_strobe", "single_lane", "partial_strobe", "all_legal")))
RESP = {0: "okay", 3: "decerr"}
CHANNEL = dict(enumerate(("aw", "w", "b", "ar", "r")))
STALL = dict(enumerate(("none", "short_wait", "medium_wait", "long_wait")))
RESPONSE_CHANNEL = {2: "b", 4: "r"}
RESPONSE_LENGTH = {0: "single_beat", 1: "multi_beat"}
POINTS = {
    "cp_burst": BURST, "cp_len": LENGTH, "cp_size": SIZE, "cp_start_lane": LANE,
    "cp_w_pos": POSITION, "cp_w_class": STRB, "cp_r_pos": POSITION, "cp_rresp_beat": RESP,
    "cp_channel": CHANNEL, "cp_stall": STALL, "cp_response_channel": RESPONSE_CHANNEL,
    "cp_response_length": RESPONSE_LENGTH,
}
CROSSES = {
    "cx_burst_len": ("cp_burst", "cp_len"),
    "cx_size_start_lane": ("cp_size", "cp_start_lane"),
    "cx_w_pos_class": ("cp_w_pos", "cp_w_class"),
    "cx_size_w_class": ("cp_size", "cp_w_class"),
    "cx_rresp_pos": ("cp_rresp_beat", "cp_r_pos"),
    "cx_channel_stall": ("cp_channel", "cp_stall"),
    "cx_response_stall": ("cp_response_channel", "cp_burst", "cp_stall"),
    "cx_response_stall_length": ("cp_response_channel", "cp_burst", "cp_response_length"),
}
EXCLUDED = {
    ("cx_burst_len", "fixed_b", "beats_256"): "FIXED is limited to 16 transfers",
    ("cx_burst_len", "wrap_b", "beats_1"): "WRAP requires 2, 4, 8 or 16 transfers",
    ("cx_burst_len", "wrap_b", "beats_256"): "WRAP requires 2, 4, 8 or 16 transfers",
    ("cx_size_w_class", "size_0", "single_lane"): "Enabling the only legal lane is All Legal",
    ("cx_size_w_class", "size_0", "partial_strobe"): "There is no strict subset of at least two legal lanes",
    ("cx_size_w_class", "size_1", "partial_strobe"): "At most two legal lanes, so a nonempty subset is Single",
    ("cx_channel_stall", "w", "long_wait"): "AW-first RAM WREADY throttle is at most three cycles",
    ("cx_response_stall_length", "b", "wrap_b", "single_beat"): "Single-beat WRAP is illegal",
    ("cx_response_stall_length", "r", "wrap_b", "single_beat"): "Single-beat WRAP is illegal",
}
UNIVERSE = {(name, label) for name, values in POINTS.items() for label in values.values()}
for name, components in CROSSES.items():
    UNIVERSE.update((name, *labels) for labels in itertools.product(*(POINTS[p].values() for p in components)))
UNIVERSE -= EXCLUDED.keys()
ENHANCED = "tb_pkg::axi4_dut_func_cov::cov_ram_enhanced"
ORIGINAL = "axi4_uvm_pkg::axi4_monitor#(32,64,4,1)::cov"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


def model_counts(samples):
    result = Counter()
    for kind, burst, length, size, lane, pos, strobe, resp, channel, stall, multi in samples:
        points = {}
        if kind == 0:
            points.update(cp_burst=BURST[burst], cp_size=SIZE[size], cp_start_lane=LANE[lane])
            if length in LENGTH:
                points["cp_len"] = LENGTH[length]
        elif kind == 1:
            points.update(cp_size=SIZE[size], cp_w_pos=POSITION[pos], cp_w_class=STRB[strobe])
        elif kind == 2:
            points.update(cp_r_pos=POSITION[pos], cp_rresp_beat=RESP[resp])
        elif kind == 3:
            points.update(cp_channel=CHANNEL[channel], cp_stall=STALL[stall])
            if channel in RESPONSE_CHANNEL:
                points.update(cp_burst=BURST[burst], cp_response_channel=RESPONSE_CHANNEL[channel])
                if stall:
                    points["cp_response_length"] = RESPONSE_LENGTH[multi]
        else:
            raise ValueError(f"Unexpected sample kind {kind}")
        result.update(points.items())
        for cross, components in CROSSES.items():
            if all(name in points for name in components):
                key = (cross, *(points[name] for name in components))
                require(key in UNIVERSE, f"An ignored combination was observed: {key}")
                result[key] += 1
    return result


def test_logs(run, size):
    names = read(run / "tests.list").splitlines()
    require(len(set(names)) == len(names) == size, f"Wrong list size in {run}")
    with (run / "test_results.csv").open(encoding="utf-8", newline="") as source:
        rows = {r["Test"]: r for r in csv.DictReader(source)}
    require(set(rows) == set(names), f"Unexpected test results list in {run}")
    coverage, samples, directions = {}, {}, {}
    for name in names:
        result = rows[name]
        require(result["Status"] == "PASS" and all(result[key] == "0" for key in (
            "UVM_ERROR", "UVM_FATAL", "Checker errors", "Sideband errors",
            "Scoreboard mismatches", "SVA failures")), f"Regression failed for {name}")
        log = read(run / "regression" / (name + ".log"))
        writes, reads = map(int, re.search(r"\[FCOV_SUMMARY\] matched_writes=(\d+) matched_reads=(\d+)", log).groups())
        require(writes == int(result["B"]) == int(result["Writes"]) and
                reads == int(result["AR"]) == int(result["Reads"]), f"Lost completed transaction: {name}")
        current = [tuple(map(int, line.split())) for line in re.findall(
            r"(?m)^UVM_INFO .*\[FCOV_SAMPLE\] ([\d ]+)$", log)]
        coverage[name] = model_counts(current)
        samples[name] = current
        dirs = defaultdict(set)
        for i, event in enumerate(current):
            if event[0] == 0:
                addr = current[i+1]
                require(addr[0] == 3 and addr[8] in (0, 3), f"Unpaired transaction address: {name}")
                dirs[addr[8]].add(tuple(event[1:5]))
        directions[name] = dirs
        require(sum(s[0] == 0 for s in current) == writes + reads and
                sum(s[0] == 1 for s in current) == int(result["W"]) and
                sum(s[0] == 2 for s in current) == int(result["R"]), f"Inconsistent beat counts: {name}")
    return rows, coverage, samples, directions


def group_scores(report):
    text = read(report / "groups.txt")
    return {name: (int(hit), int(total)) for hit, total, name in re.findall(
        r"(?m)^(\d+)\s+(\d+)\s+[\d.]+\s+[\d.]+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\S+)\s*$", text)}


def checked_urg(run, tests):
    report = run / "urg/functional"
    report_text = read(report / "grpinfo.txt")
    # The group definition and group-instance sections have duplicate part tables.
    group = report_text.split(f"Summary for Group   {ENHANCED}", 1)[1]
    group = re.split(r"(?m)^Group Instance : |^Summary for Group\s+", group, maxsplit=1)[0]
    test_ids = dict(re.findall(r"(?m)^(T\d+)\s+\S*/(axi4_dut_\w+_test)\s+", read(report / "tests.txt")))
    actual = Counter()
    sections = re.split(r"(?m)^Summary for (Variable|Cross) (\w+)[ \t]*\n", group)
    require(set(sections[2::3]) == POINTS.keys() | CROSSES.keys(), f"Unexpected group definition in {run}")
    for kind, name, table in zip(sections[1::3], sections[2::3], sections[3::3]):
        n = 1 if kind == "Variable" else len(CROSSES[name])
        for line in table.splitlines():
            cols = line.split()
            key = (name, *cols[:n])
            if key not in UNIVERSE or len(cols) < n+2 or not cols[n].isdigit() or cols[n+1] != "1":
                continue
            count = int(cols[n])
            require(key not in actual, f"Duplicate URG row {key}")
            actual[key] = count
            for test_id, hits in re.findall(r"\b(T\d+)\s+(\d+)\b", " ".join(cols[n+2:])):
                require(tests[test_ids[test_id]][key] == int(hits), f"URG contribution mismatch {key}/{test_id}")

    traced = sum(tests.values(), Counter())
    require(all(actual[key] == traced[key] for key in UNIVERSE), f"URG vs sample ledger count mismatch in {run}")
    covered = sum(value > 0 for value in actual.values())
    require(group_scores(report) == {ENHANCED: (covered, len(UNIVERSE)), ORIGINAL: (73, 79)},
            f"Invalid or mixed coverage scope in {run}")
    return actual


def csv_write(path, header, rows):
    with path.open("w", encoding="utf-8-sig", newline="") as fd:
        out = csv.writer(fd)
        out.writerow(header)
        out.writerows(rows)


def check_vip(run, source):
    script = source / "coverage_closure_final/scripts/verify_vip_response.py"
    spec = importlib.util.spec_from_file_location("vip_check", script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    result = mod.check_regression(run, 36)
    require(group_scores(run / "urg/functional") == {ORIGINAL: (79, 79)}, "VIP group was altered")
    require(re.search(r"(?m)^Failure\s+0\b", read(run / "urg/assertions/asserts.txt")), "VIP assertion failure")
    return result


def main(root, output):
    base, final, vip = (root / "reports" / name for name in ("baseline", "final", "vip"))
    require(read(base / "model.sha256").split()[0] == read(final / "model.sha256").split()[0],
            "Enhanced model was not frozen")
    base_rows, base_tests, _, base_dirs = test_logs(base, 26)
    final_rows, final_tests, wave_expected, final_dirs = test_logs(final, 30)
    require(all(final_tests[test] == counts for test, counts in base_tests.items()), "Inherited hits changed")
    prior, after = checked_urg(base, base_tests), checked_urg(final, final_tests)
    all_shapes = {key[1:] for key in UNIVERSE if key[0] == "cx_burst_len"}
    for channel in (0, 3):
        shapes = {(BURST[b], LENGTH[l]) for dirs in base_dirs.values()
                  for b, l, _, _ in dirs[channel] if l in LENGTH}
        require(shapes == all_shapes, "Burst/Length must have real coverage in both directions")
        pairs = {(size, lane) for _, _, size, lane in final_dirs["axi4_dut_fc_size_lane_test"][channel]}
        require(pairs == set(itertools.product(range(4), range(8))), "Size/Lane not exercised in both directions")

    vip_tests = check_vip(vip, root / "source/final")
    output.mkdir(parents=True, exist_ok=True)
    new_tests = [case for case in final_tests if case not in base_tests]
    with (output / "WAVEFORM_VERIFIED.txt").open("w", encoding="utf-8") as evidence:
        for case in new_tests:
            samples, summary = wave_samples(final / "waves" / (case + ".vcd"))
            require(Counter(samples) == Counter(wave_expected[case]), f"Pin waveform mismatch: {case}")
            print(case, "PASS", summary, file=evidence)

    def contributors(tests, key, allowed=None):
        return " | ".join(f"{test}={counter[key]}" for test, counter in tests.items()
                          if counter[key] and (allowed is None or test in allowed))

    bins = sorted(UNIVERSE)
    csv_write(output / "COVERAGE_BIN_ATTRIBUTION.csv",
              ["kind", "point_or_cross", "bin", "baseline_hits", "final_hits", "baseline_tests",
               "final_tests", "new_tests"], [
                  ("cross" if k[0] in CROSSES else "point", k[0], "/".join(k[1:]), prior[k], after[k],
                   contributors(base_tests, k), contributors(final_tests, k),
                   contributors(final_tests, k, new_tests)) for k in bins])
    holes = [(k[0], "/".join(k[1:]), "Resolved" if after[k] else "Open", prior[k], after[k],
              contributors(final_tests, k, new_tests), "See modeled scenario and actual handshakes")
             for k in bins if not prior[k]]
    holes += [(k[0], "/".join(k[1:]), "Excluded by definition", "", "", "", reason)
              for k, reason in EXCLUDED.items()]
    csv_write(output / "COVERAGE_HOLE_INVENTORY.csv",
              ["cross", "bin", "status", "baseline_hits", "final_hits", "new_tests", "basis"], holes)
    matrix = []
    for scope, rows in (("RAM baseline", base_rows), ("RAM final", final_rows)):
        folder = "baseline" if scope.endswith("baseline") else "final"
        for test, row in rows.items():
            new_hits = sum(final_tests[test][k] > 0 for k in bins if not prior[k]) if test in new_tests else 0
            matrix.append((scope, test, row["Seed"], row["Status"], row["SIM_RC"],
                           *(row[ch] for ch in ("AW","W","B","AR","R")), row["UVM_ERROR"], row["UVM_FATAL"],
                           row["Checker errors"], row["Scoreboard mismatches"], new_hits,
                           f"reports/{folder}/regression/{test}.log"))
    for test, counts in vip_tests.items():
        matrix.append(("VIP guard", test, 1, "PASS", 0, *counts, 0, 0, 0, 0, "",
                       f"reports/vip/tests/{test}.log"))
    csv_write(output / "TEST_MATRIX.csv",
              ["scope", "test", "seed", "status", "sim_rc", "aw", "w", "b", "ar", "r", "uvm_error",
               "uvm_fatal", "checker_errors", "scoreboard_mismatches", "baseline_holes_hit", "log"], matrix)
    print(f"RAM baseline {sum(prior[k]>0 for k in bins)}/{len(bins)}, "
          f"RAM final {sum(after[k]>0 for k in bins)}/{len(bins)}, original RAM 73/79, VIP 79/79")
    for test in new_tests:
        by_cross = Counter(k[0] for k in bins if not prior[k] and final_tests[test][k])
        print(test, dict(by_cross), "total", sum(by_cross.values()))


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
