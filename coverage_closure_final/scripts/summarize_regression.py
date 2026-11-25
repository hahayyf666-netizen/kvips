#!/usr/bin/env python
# Compatible with the CentOS 7 system Python.
from __future__ import print_function
import csv
import os
import re
import sys


def extract(pattern, text):
    hits = re.findall(pattern, text, re.M)
    return int(hits[-1]) if hits else None


run = sys.argv[1]
tests = [line.strip() for line in open(os.path.join(run, 'tests.list')) if line.strip()]
uninit_expected = {'strobe': 5, 'unaligned': 8, 'ral': 2,
                   'burst_size_cross': 16, 'unaligned_incr_e2e': 1}
solver_probe = {
    'wrap_alignment': ('Constraint PASS: 0x2008 accepted', 'Constraint PASS: 0x2002 rejected'),
    '4kb_boundary': ('4KB PASS: 0x1FF0 accepted', '4KB PASS: 0x1FF8 rejected'),
}
prefix, suffix = 'axi4_dut_', '_test'
rows = []
for test in tests:
    label = test[len(prefix):-len(suffix)]
    base = os.path.join(run, 'regression', test)
    log = open(base + '.log').read()
    rc = int(open(base + '.rc').read().strip())
    summary = re.findall(r'^.*AXI4 SB summary:.*$', log, re.M)
    checker = re.findall(r'^.*AXI4_CHK.*\bAW=.*$', log, re.M)
    sb = summary[-1] if summary else ''
    chk = checker[-1] if checker else ''
    counts = [extract(r'\b' + name + r'=(\d+)', chk) for name in ('AW', 'W', 'B', 'AR', 'R')]
    wr, rd, wrerr, uninit, mismatch = [extract(r'\b' + name + r'=(\d+)', sb)
                                     for name in ('wr_txns', 'rd_txns', 'wr_err',
                                                  'rd_uninit_warn_beats', 'rd_mismatch_beats')]
    checks = [extract(r'\b' + name + r'=(\d+)', chk) for name in ('errors', 'sideband_errors')]
    uvm = [extract(r'^UVM_' + level + r'\s*:\s*(\d+)\s*$', log)
           for level in ('WARNING', 'ERROR', 'FATAL')]
    sva_fail = len(re.findall(r'(?im)\b(?:a_kvips_\w+: started at .* failed at|assertion (?:.* )?failed\b)', log))
    violations = []
    vcs_errors = re.findall(r'^Error-\[([^]]+)\]', log, re.M)
    approved_probe = (
        label in solver_probe and rc == 2 and sorted(vcs_errors) == ['CNST-CIF', 'CNST-ICE']
        and all(log.count(marker) == 1 for marker in solver_probe[label]))
    if not ((rc == 0 and not vcs_errors and label not in solver_probe) or approved_probe):
        violations.append('unexpected simulator status or constraint result')
    if uvm[1:] != [0, 0] or sva_fail:
        violations.append('simulator/UVM/SVA')
    if ('[RNTST] Running test ' + test + '...') not in log:
        violations.append('test identity')
    if any(value is None or value <= 0 for value in counts + [wr, rd]):
        violations.append('no complete AXI traffic')
    elif counts[0] != wr or counts[2] != wr or counts[3] != rd:
        violations.append('handshake/scoreboard count disagreement')
    if checks != [0, 0] or mismatch != 0:
        violations.append('checker/data compare')
    expected_write_errors = {'error': 1, 'closure_toggle': 16}
    if wrerr != expected_write_errors.get(label, 0):
        violations.append('unexpected write response count')
    if label in uninit_expected and uninit != uninit_expected[label]:
        violations.append('uninitialized read count')
    elif label == 'narrow' and not (uninit is not None and counts[4] is not None and 0 <= uninit <= counts[4]):
        violations.append('uninitialized read range')
    elif label not in uninit_expected and label != 'narrow' and uninit != 0:
        violations.append('unexpected uninitialized read')
    if label == 'id_width' and (wr, rd) != (3, 3):
        violations.append('ID width transaction counts')
    if label == 'closure_toggle' and ((wr, rd) != (181, 197) or
                                     log.count('patterns=132 address_cases=29 decerr_pairs=16 sentinel_reads=16') != 1):
        violations.append('address/data pattern checks')
    if label == 'closure_random':
        generated = extract(r'\bgenerated_pairs=(\d+)', log)
        prefill = extract(r'\bprefill_writes=(\d+)', log)
        random_beats = extract(r'\bbeats_per_direction=(\d+)', log)
        if (generated != 132 or prefill != 8 or random_beats is None or
                extract(r'\brandomize_failures=(\d+)', log) != 0 or
                (wr, rd) != (generated + prefill, generated) or
                counts[1] != random_beats + 256*prefill or counts[4] != random_beats or
                len(re.findall(r'^UVM_INFO .*\[CLOSURE_RANDOM_SAMPLE\] index=', log, re.M)) != generated):
            violations.append('random generation/readback counts')
    if label == 'closure_bready':
        hold = re.findall(r'\[CLOSURE_B_SUMMARY\].*b_handshakes=(\d+) stalled_responses=(\d+) '
                          r'stalled_cycles=(\d+) max_run=(\d+) hold_errors=(\d+)', log)
        if (wr, rd) != (64, 64) or len(hold) != 1:
            violations.append('BREADY handshake count')
        else:
            total, stalled, cycles, longest, errors = map(int, hold[0])
            if total != 64 or not (0 < stalled <= 64) or cycles < stalled or longest < 2 or errors:
                violations.append('BREADY stall or hold')
    status = 'FAIL' if violations else 'PASS'
    rows.append([test, 1, status, rc] + uvm + checks + counts +
                [wr, rd, wrerr, uninit, mismatch, sva_fail, int(approved_probe),
                 '; '.join(violations), base + '.log'])
    print('%s %s%s' % (status, test, (': ' + '; '.join(violations)) if violations else ''))

mode = 'wb' if sys.version_info[0] == 2 else 'w'
with open(os.path.join(run, 'test_results.csv'), mode) as handle:
    writer = csv.writer(handle)
    writer.writerow(['Test', 'Seed', 'Status', 'SIM_RC', 'UVM_WARNING', 'UVM_ERROR', 'UVM_FATAL',
                     'Checker errors', 'Sideband errors', 'AW', 'W', 'B', 'AR', 'R',
                     'Writes', 'Reads', 'Write response errors', 'Uninitialized reads',
                     'Scoreboard mismatches', 'SVA failures', 'Expected constraint rejection',
                     'Reason', 'Log'])
    writer.writerows(rows)
passed = sum(row[2] == 'PASS' for row in rows)
print('PASS=%d FAIL=%d TOTAL=%d' % (passed, len(rows) - passed, len(rows)))
sys.exit(0 if len(rows) and passed == len(rows) else 1)
