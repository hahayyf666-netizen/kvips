#!/usr/bin/env python3
"""Join the passing VCS ledgers with the independently gated evidence."""
import csv
import re
import sys
from collections import Counter
from pathlib import Path


def load(path):
    with path.open(newline='', encoding='utf-8-sig') as handle:
        rows = list(csv.DictReader(handle))
    result = {row['Test']: row for row in rows}
    if len(result) != len(rows) or any(row['Status'] != 'PASS' for row in rows):
        raise ValueError('Duplicate or failing case in ' + str(path))
    return result


def write(path, headers, rows):
    with path.open('w', newline='', encoding='utf-8-sig') as handle:
        writer = csv.writer(handle)
        writer.writerow(headers)
        writer.writerows(rows)


base, final, out = [Path(arg) for arg in sys.argv[1:]]
old, new = load(base / 'test_results.csv'), load(final / 'test_results.csv')
assert len(old) == 23 and len(new) == 26
assert set(old) <= set(new)
header = ['Test', 'Category', 'Seed', 'Baseline', 'Final', 'Baseline SIM_RC', 'Final SIM_RC',
          'UVM_ERROR', 'UVM_FATAL', 'Checker errors', 'Scoreboard mismatches', 'AW', 'W', 'B',
          'AR', 'R', 'Evidence', 'Intent']
rows = []
intent = {
    'closure_toggle': '132 data patterns; 29 address bits/regions; 16 DECERR pairs and sentinels',
    'closure_random': '132 constrained pairs; narrow masks; address/length/size/ID/data/delay',
    'closure_bready': '64 bursts per direction; B hold; known SVA; captured waveform / DUTDBG',
    'wrap_alignment': 'Expected solver rejection then valid WRAP traffic',
    '4kb_boundary': 'Expected solver rejection then valid 4KB-edge traffic',
    'error': 'DUT expected DECERR for one write and one read',
    'len_256': '256 beats in each direction',
    'id_width': 'Three writes and reads with ID 0/F/0',
    'lane_sweep': 'Starting byte lanes 0–7',
}
for name, row in new.items():
    label = name[len('axi4_dut_'):-len('_test')]
    prior = old.get(name, {})
    rows.append([name, 'DUT positive', row['Seed'], prior.get('Status', '—'), row['Status'],
                 prior.get('SIM_RC', '—'), row['SIM_RC']]
                + [row[field] for field in header[7:16]]
                + ['reports/final/regression/' + name + '.log',
                   intent.get(label, 'Existing DUT regression')])

ev = 'METHOD_EVIDENCE/'
rows += [
    ['axi4_dut_addr_ref_test', 'Algorithm only', 1, 'PASS', '—', 0, '—',
     0, 0, '—', '—', 0, 0, 0, 0, 0, ev+'functional_coverage/addr_ref_runner.log',
     '42,717 beats and 42,765 comparisons; separate compile/replay'],
    ['closure_bready_control', 'Dedicated A/B control', 1, '—', 'PASS', '—', 0,
     0, 0, 0, 0, 64, 256, 64, 64, 256, ev+'backpressure/control/control.log',
     'Same 64 bursts, pipelined BREADY random disabled'],
]
for state, folder in [('Before', 'early_w_before_verified'), ('After', 'early_w_after')]:
    for variant in ('legal', 'injected'):
        err = int(state == 'After' and variant == 'injected')
        rows.append(['early_w_'+state.lower()+'_'+variant, 'Checker-only', 1,
                     ('Miss reproduced' if variant == 'injected' else 'PASS') if state == 'Before' else '—',
                     (('Expected error detected' if err else 'PASS') if state == 'After' else '—'),
                     (0 if state == 'Before' else '—'), (0 if state == 'After' else '—'),
                     err, 0, err, '—', 4, 6, 4, 0, 0,
                     ev+'negative_tests/'+folder+'/'+variant+'.log',
                     'Two complete early bursts, one overlapping AW and one AW-first control'])
for name, aw, w, b, ar, r, note in [
        ('run_wstrb_negative', 4, 296, 4, 4, 296, 'One illegal WSTRB'),
        ('run_wlast_missing', 1, 4, 1, 0, 0, 'Missing WLAST; orphan B'),
        ('run_wlast_premature', 1, 2, 1, 0, 0, 'Premature WLAST; length mismatch')]:
    rows.append([name, 'Historical injection', '—', '—', 'Log confirmed expected error', '—', '—',
                 1, 0, 1, '—', aw, w, b, ar, r, ev+'negative_tests/'+name+'.log', note])
for name, note in [('AW Hold', 'Assignment records an AW Hold negative experiment'),
                   ('4KB SVA', 'Assignment records two detections (AW and AR)')]:
    rows.append([name, 'Historical description', *(['—']*2), 'Source log unavailable', *(['—']*11),
                 'REGRESSION_SUMMARY.md', note])
assert all(len(row) == len(header) for row in rows)
write(out / 'TEST_MATRIX.csv', header, rows)

raw = (final / 'regression/axi4_dut_closure_random_test.log').read_text()
pattern = (r'\[CLOSURE_RANDOM_SAMPLE\] index=(\d+) address=([0-9a-f]+) burst=(\d+) '
           r'len=(\d+) size=(\d+) id=(\d+) delay=(\d+)')
samples = re.findall(pattern, raw)
assert [int(sample[0]) for sample in samples] == list(range(132))
assert sum(int(sample[3])+1 for sample in samples) == 7089
sample_csv = out / 'RANDOM_SAMPLES.csv'
write(sample_csv, ['Sample', 'Address', 'Burst', 'AxLEN', 'Beats', 'AxSIZE', 'ID', 'Delay cycles'],
      [[int(i), '0x'+addr, ('FIXED', 'INCR', 'WRAP')[int(burst)], int(length), int(length)+1,
        int(size), int(ident), int(delay)] for i, addr, burst, length, size, ident, delay in samples])
for name, index in [('BURST', 2), ('LEN', 3), ('SIZE', 4), ('ID', 5), ('DELAY', 6)]:
    distribution = Counter(int(sample[index]) for sample in samples)
    print(name, 'range', min(distribution), max(distribution), 'count', sorted(distribution.items()))
print('TEST_MATRIX', len(rows), 'rows; RANDOM_SAMPLES', len(samples))
