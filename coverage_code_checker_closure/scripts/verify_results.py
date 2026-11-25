#!/usr/bin/env python3
"""Validate final simulations, VCDs and raw URG results and write evidence tables."""
import argparse
import csv
import re
from collections import Counter
from pathlib import Path

from review_coverage import checker_code, grouped_assertions, load_inventory, key
from verify_waveforms import (check_completed_pair, check_idle, check_arlock, check_reset,
                              counts, cycles, handshakes, require)


W_ORPHAN = "W beat seen with no outstanding AW"
W_MISSING = "Missing WLAST on final W beat"
W_PREMATURE = "Unexpected WLAST before final W beat"
W_COUNT = "WLAST asserted but beats_left != 0 after decrement"
W_OVERFLOW = "W beat overflow (beats_left==0)"
B_ORPHAN = "B seen with BID having no completed write data"
B_LOCK = "BRESP=EXOKAY observed for non-exclusive write"
R_ORPHAN = "R beat seen with no outstanding AR for RID"
R_MISSING = "Missing RLAST on final R beat"
R_PREMATURE = "Unexpected RLAST before final R beat"
R_OVERFLOW = "R beat overflow (beats_left==0)"
R_LOCK = "RRESP=EXOKAY observed for non-exclusive read"

# Expected count, LAST pattern and exact diagnostic. A diagnostic is anchored
# to the actual edge that completed that channel transfer.
FAULTS = {
    "w_without_aw":       ((0,1,0,0,0), (1,), (), ((424,W_ORPHAN,"w",0),), {423}),
    "missing_wlast":       ((1,2,0,0,0), (0,0), (), ((432,W_MISSING,"w",1),), {431}),
    "premature_wlast":     ((1,1,0,0,0), (1,), (), ((435,W_PREMATURE,"w",0),(443,W_COUNT,"w",0)), {434,442}),
    "w_overflow":          ((1,3,0,0,0), (0,0,0), (), ((432,W_MISSING,"w",1),(429,W_OVERFLOW,"w",2)), {428,431}),
    "orphan_b":            ((0,0,1,0,0), (), (), ((457,B_ORPHAN,"b",0),), {456,465}),
    "b_exokay_unlocked":   ((1,1,1,0,0), (1,), (), ((462,B_LOCK,"b",0),), {461}),
    "orphan_r":            ((0,0,0,0,1), (), (1,), ((479,R_ORPHAN,"r",0),), {478}),
    "missing_rlast":       ((0,0,0,1,2), (), (0,0), ((486,R_MISSING,"r",1),), {485}),
    "premature_rlast":     ((0,0,0,1,1), (), (1,), ((489,R_PREMATURE,"r",0),), {488}),
    "r_overflow":          ((0,0,0,1,3), (), (0,0,0), ((486,R_MISSING,"r",1),(495,R_OVERFLOW,"r",2)), {485,494}),
    "r_exokay_unlocked":   ((0,0,0,1,1), (), (1,), ((492,R_LOCK,"r",0),), {491}),
}
SVA_CASE = 'aw_hold_violation'
CONTROLS = ('locked_ok_control', 'r_count_overlap_control')
POSITIVES = {
    'axi4_dut_reset_aw_test': ('aw', (2,2,1,1,2)),
    'axi4_dut_reset_b_test': ('b', (2,4,1,1,2)),
    'axi4_dut_reset_r_test': ('r', (1,2,1,2,2)),
    'axi4_dut_arlock_toggle_test': ('lock', (1,1,1,3,3)),
    'axi4_dut_idle_rready_test': ('idle', (1,1,1,1,1)),
}


def read(path):
    return path.read_text(encoding='utf-8', errors='replace')


def write_csv(path, columns, rows):
    with path.open('w', encoding='utf-8-sig', newline='') as file:
        out = csv.writer(file)
        out.writerow(columns)
        out.writerows(rows)


def reset_epochs(samples):
    active = [(time, pins) for time, pins in samples if pins['areset_n'] == 1]
    candidate = [i for i in range(1, len(samples))
                 if samples[i-1][1]['areset_n'] == 1 and samples[i][1]['areset_n'] == 0]
    require(len(candidate) == 1, 'Expected one reset after the fault phase')
    start = candidate[0]
    second = samples[start:start+2]
    require(len(second) == 2 and all(pins['areset_n'] == 0 for _, pins in second),
            'Expected two sampled reset cycles')
    require(all(second[-1][1][name] == 0 for name in ('kvips_outs_w','kvips_outs_r','bvalid','rvalid')),
            'Stale state following reset')
    return [row for row in active if row[0] < second[0][0]], [row for row in active if row[0] > second[1][0]]


def check_fault_wave(case, first):
    expected_counts, wl, rl, diagnostics, branches = FAULTS[case]
    e, changes = handshakes(first)
    require(counts(e) == expected_counts and not changes, f'{case} fault handshake counts')
    for ch, pattern in (('w', wl), ('r', rl)):
        require(tuple(beat['last'] for beat in e[ch]) == pattern, f'{case} wrong LAST pattern')
    for ch in ('aw', 'ar'):
        for req in e[ch]:
            n = int(case in ('missing_wlast', 'premature_wlast', 'w_overflow',
                             'missing_rlast', 'premature_rlast', 'r_overflow'))
            require((req['id'], req['addr'], req['len'], req['size'], req['burst'], req['lock']) ==
                    (7, 0x100, n, 3, 1, 0), f'{case} prepared wrong transaction')
    for ch in ('b','r'):
        for beat in e[ch]:
            target_id = 12 if case == 'orphan_'+ch else 7
            resp = int(case == ch+'_exokay_unlocked')
            require((beat['id'], beat['resp']) == (target_id, resp), f'{case} wrong response')
    return [(line, msg, e[ch][idx]['time']) for line, msg, ch, idx in diagnostics], branches


def check_control_wave(case, first, log):
    e, changes = handshakes(first)
    require(not changes, 'Unexpected hold change')
    if case == 'locked_ok_control':
        require(counts(e) == (3,3,3,3,3), 'Wrong locked control counts')
        for req_ch, resp_ch in (('aw','b'), ('ar','r')):
            require([r['lock'] for r in e[req_ch]] == [0,1,0] and
                    [r['resp'] for r in e[resp_ch]] == [0,1,0], 'Unexpected control LOCK or response')
            require(all((r['id'], r['addr'], r['len'],r['size'],r['burst']) == (7,0x100,0,3,1)
                        for r in e[req_ch]), 'Incorrect exclusive request')
        require(e['ar'][1]['time'] < e['r'][1]['time'] < e['aw'][1]['time'] < e['b'][1]['time'],
                'Exclusive read/write order')
        return set()
    require(counts(e) == (0,0,0,2,2) and [r['id'] for r in e['ar']] == [7,8] and
            [r['id'] for r in e['r']] == [7,8], 'Incorrect overlap transfer counts/IDs')
    require(e['ar'][1]['time'] == e['r'][0]['time'] < e['r'][1]['time'], 'Missing same-edge AR/RLAST')
    require(any(t == e['r'][1]['time'] and pins['kvips_outs_r'] == 0 for t, pins in first) and
            re.search(r'^OVERLAP_COUNTER time=\d+ id=8 queued=1 outstanding=0$', log, re.M),
            'Counter overlap discrepancy was not observed')
    return {502}


def verify_checker(root, source):
    run = root / 'reports/negative'
    original = root / 'reports/baseline/urg/all'
    inv = load_inventory(source)
    baseline = {key(h): h for h in inv.extract_code(original, source)
                if h.metric == 'BRANCH' and h.module == 'axi4_if' and not h.covered}
    names = (run / 'tests.list').read_text().splitlines()
    require(names == [*FAULTS, SVA_CASE, *CONTROLS], 'Invalid test list')
    out, waves, seen = [], [], set()
    for case in names:
        log = read(run / 'regression' / (case+'.log'))
        rc = int(read(run / 'regression' / (case+'.rc')).strip())
        report = run / 'urg/by_test' / case
        actual = [(int(line), msg, int(time)) for line, time, msg in re.findall(
            r'^Error: "[^"]*/axi4_if_sva\.svh", (\d+): top\.axi: at time (\d+) ps\s*\n'
            r'KVIPS_AXI4_ASSERT: ([^\r\n]+)$', log, re.M)]
        require(log.count('KVIPS_AXI4_ASSERT:') == len(actual) == len(re.findall(r'^Error:', log, re.M)),
                f'{case} unparsed checker diagnostic')
        require(re.findall(r'^CHECKER_CONFIGURATION assertions=1 excl=1 known=1$', log, re.M) ==
                ['CHECKER_CONFIGURATION assertions=1 excl=1 known=1'], f'{case} assertion config')
        for marker in ('CASE_BEGIN', 'CASE_END', 'RESET_CLEAR', 'RECOVERY_PASS'):
            require(len(re.findall(rf'^CHECKER_{marker} {case} time=\d+$', log, re.M)) == 1,
                    f'{case} missing {marker}')
        require(not re.search(r'^(?:Fatal:|Error-\[|UVM_(?:ERROR|FATAL)\b)', log, re.M), f'{case} fatal/harness error')
        first, second = reset_epochs(cycles(run / 'waves' / (case+'.vcd')))
        clean, _ = handshakes(second)
        check_completed_pair(clean, 0x100, 7, 0x6ac10c5510bef91a, 0)
        if case in FAULTS:
            expected, branches = check_fault_wave(case, first)
            require(rc == 2, f'{case} VCS exit {rc}')
        else:
            expected = []
            if case in CONTROLS:
                branches = check_control_wave(case, first, log)
                require(rc == 0, f'{case} VCS exit {rc}')
            else:
                edges, changes = handshakes(first, hold_exception='aw')
                require(counts(edges) == (1,0,0,0,0) and len(changes) == 1 and
                        changes[0][2:] == (0x100,0x108), 'Incorrect AW hold injection')
                branches = set()
        require(actual == expected, f'{case}: wrong diagnostics {actual!r}')
        assertions = grouped_assertions(report)
        failed = {k: x[2] for k, x in assertions.items() if x[2]}
        expected_sva = {'top.axi.a_kvips_aw_hold': 1} if case == SVA_CASE else {}
        require(failed == expected_sva, f'{case}: unexpected assertion result {failed}')
        if case == SVA_CASE:
            require(rc == 2, f'{case} VCS exit {rc}')
            require(len(re.findall(r'a_kvips_aw_hold: started at .* failed at', log)) == 1,
                    'AW hold assertion failure missing from simulation log')
        if case == 'locked_ok_control':
            require(all(assertions[f'top.axi.a_kvips_{ch}_excl_restrictions'][1] > 0 for ch in ('aw','ar')),
                    'LOCK control did not get nonvacuous success')
        hits = {key(h) for h in checker_code(inv, report, source) if h.metric == 'BRANCH' and h.covered}
        gained = {int(baseline[k].line) for k in hits & baseline.keys()}
        require(gained == branches, f'{case}: unexpected new branch hits {gained}, wanted {branches}')
        seen.update(gained)
        proc_text = ' | '.join(msg for _, msg, _ in actual)
        sva_text = ' | '.join(f'{s}={n}' for s,n in failed.items())
        expected_text = ' | '.join(msg for _, msg, _ in expected)
        actual_errors = len(actual) + sum(failed.values())
        out.append([case, 'Procedural $error' if case in FAULTS else 'SVA' if case == SVA_CASE else 'Control',
                    rc, expected_text or ' | '.join(expected_sva),
                    proc_text or sva_text, len(expected) + sum(expected_sva.values()), actual_errors,
                    'Yes' if len(expected) > 1 else 'No', 'No', 'PASS',
                    ' '.join(map(str, sorted(gained))), 'PASS',
                    f'reports/negative/regression/{case}.log',
                    f'reports/negative/urg/by_test/{case}/modinfo.txt',
                    f'reports/negative/waves/{case}.vcd'])
        waves.append(f'{case} PASS; errors={actual_errors}, post-reset clean AW/W/B/AR/R=1/1/1/1/1')
    require(seen == {int(h.line) for h in baseline.values()}, 'Missing unattributed interface branch')
    assert_total = sum(row[6] for row in out if row[1] == 'SVA')
    proc_total = sum(row[6] for row in out if row[1] == 'Procedural $error')
    require((proc_total, assert_total) == (14,1), 'Wrong total diagnostic budget')
    write_csv(root / 'NEGATIVE_TEST_MATRIX.csv',
              ['Test', 'Class', 'VCS Exit', 'Expected Signatures', 'Actual Signatures',
               'Expected Errors', 'Actual Errors', 'Related Diagnostics', 'Unexpected Errors',
               'Reset Recovery', 'New Branch Lines', 'Status', 'Log', 'URG Report', 'VCD'], out)
    return waves


def assert_failures(report, expected):
    rows = grouped_assertions(report)
    require(rows and sum(value[2] for value in rows.values()) == expected, f'Assertion failures in {report}')
    return rows


def verify_ram(root):
    baseline = root / 'reports/baseline'
    positive = root / 'reports/positive'
    for run in (baseline, positive):
        require(read(run / 'regression-verdict.log').rstrip().endswith('PASS=30 FAIL=0 TOTAL=30'),
                f'Legacy RAM regression failed in {run.name}')
        with (run / 'test_results.csv').open(newline='') as file:
            data = list(csv.DictReader(file))
            require(len(data) == 30 and all(r['Status'] == 'PASS' for r in data), 'RAM test matrix')
    require(read(baseline / 'tests.list') == read(positive / 'tests.list'), 'RAM test list drift')
    require(read(positive / 'additional-tests.list').splitlines() == list(POSITIVES), 'New RAM test list')
    all_sva = assert_failures(positive / 'urg/assertions', 0)
    require(sum(x[1] > 0 for k,x in all_sva.items() if k.startswith('top.axi.')) == 27, 'Project SVA coverage')
    waves = []
    for test, (case, expected) in POSITIVES.items():
        log = read(positive / 'regression' / (test+'.log'))
        require(read(positive / 'regression' / (test+'.rc')).strip() == '0', f'{test} VCS exit')
        require(re.findall(r'^CODE_SCENARIO_PASS .*$', log, re.M) == ['CODE_SCENARIO_PASS '+test], 'Missing pass marker')
        require(re.findall(r'^UVM_(?:ERROR|FATAL)\s*:\s*(\d+)\s*$', log, re.M) == ['0','0'], 'Unexpected UVM diagnostics')
        require(not re.search(r'^(Error[-:]|Fatal:|KVIPS_AXI4_ASSERT:)', log, re.M), 'Unexpected VCS diagnostics')
        ch = re.search(r'Channel checker summary: AW=(\d+) W=(\d+) B=(\d+) AR=(\d+) R=(\d+) errors=0 sideband_errors=0',
                       log)
        require(ch and tuple(map(int, ch.groups())) == expected, f'{test} handshake stats mismatch')
        wave = positive / 'waves' / (test+'.vcd')
        if case == 'lock':
            verdict = check_arlock(wave)
            rows = assert_failures(positive / 'urg/by_test' / test, 0)
            require(rows['top.axi.a_kvips_ar_excl_restrictions'][1] == 1 and
                    rows['top.axi.a_kvips_aw_excl_restrictions'][1] == 0,
                    'ARLOCK restriction nonvacuous success')
        elif case == 'idle':
            verdict = check_idle(wave)
            require('DUTDBG STATE arv=0 arr=1 rd_active=0 rv=0 rr=1' in log, 'Missing idle debug trace')
        else:
            verdict = check_reset(wave, case)
            require(re.findall(r'^RESET_CONTEXT stage=(\w+)', log, re.M) ==
                    ['pending_'+case,'reset_sampled','released','recovered'], 'Missing context trace')
        waves.append(test+' PASS; '+verdict)
    return waves


def verify_functional(root, source):
    import sys
    sys.path.insert(0, str(source / 'coverage_closure_final/scripts'))
    sys.path.insert(0, str(source / 'coverage_functional_enhancement/scripts'))
    from verify_vip_response import check_cases
    from verify_functional_coverage import test_logs, checked_urg, group_scores, check_vip
    base, final, vip = (root / 'reports' / name for name in ('baseline', 'positive', 'vip'))
    _, base_tests, _, _ = test_logs(base, 30)
    _, old_tests, _, _ = test_logs(final, 30)
    require(base_tests == old_tests, 'Original 30 RAM tests changed functional contributions')
    for run, sample_counts in ((base, base_tests), (final, old_tests)):
        coverage = checked_urg(run, sample_counts)
        require(sum(n > 0 for n in coverage.values()) == len(coverage) == 185, 'Enhanced model count')
    combined = read(final / 'urg/functional_all/dashboard.txt')
    require(re.search(r'^Number of tests: 35$', combined, re.M) and re.search(r'\b258/264\b', combined),
            'New RAM tests changed functional coverage totals')
    require(group_scores(final / 'urg/functional_all') == group_scores(final / 'urg/functional'),
            'New RAM tests changed individual functional groups')
    vc = check_vip(vip, source)
    check_cases(vip, vc)
    assert_failures(vip / 'urg/assertions', 0)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('stage', type=Path)
    p.add_argument('source', type=Path)
    args = p.parse_args()
    waves = verify_ram(args.stage)
    waves += verify_checker(args.stage, args.source.resolve())
    verify_functional(args.stage.resolve(), args.source.resolve())
    (args.stage / 'WAVEFORM_VERIFIED.txt').write_text('\n'.join(waves)+'\n', encoding='utf-8')
    print('VERIFIED: RAM 30/30 + 5/5, Checker 11 procedural + 1 SVA + 2 controls, VIP 36/36')
    print('VERIFIED: 185/185 RAM enhanced, 73/79 RAM original, 79/79 VIP')


if __name__ == '__main__':
    main()
