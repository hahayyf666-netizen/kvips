#!/usr/bin/env python3
"""Check B-channel hold at rising clock edges using pre-edge VCD values."""
import sys
from pathlib import Path


def check(path):
    signals = ('aclk', 'areset_n', 'bvalid', 'bready', 'bid', 'bresp')
    scope, codes, values, changes = [], {}, {}, {}
    totals = {'handshakes': 0, 'stalled_responses': 0, 'stalled_cycles': 0,
              'max_run': 0, 'hold_errors': 0}
    held, run = None, 0

    def sample_step():
        nonlocal held, run
        if changes.get('aclk') == '1' and values.get('aclk') == '0' and values.get('areset_n') == '1':
            valid, ready = values.get('bvalid'), values.get('bready')
            payload = tuple(values.get(name) for name in ('bid', 'bresp'))
            if held is not None and (valid != '1' or payload != held):
                totals['hold_errors'] += 1
            if valid == '1' and ready == '0':
                totals['stalled_cycles'] += 1
                held = payload
                run += 1
            if valid == '1' and ready == '1':
                totals['handshakes'] += 1
                if run:
                    totals['stalled_responses'] += 1
                    totals['max_run'] = max(totals['max_run'], run)
                held, run = None, 0
        values.update(changes)
        changes.clear()

    data = False
    for row in path.read_text().splitlines():
        fields = row.strip().split()
        if not fields:
            continue
        head = fields[0]
        if not data:
            if head == '$scope':
                scope.append(fields[2])
            elif head == '$upscope':
                scope.pop()
            elif head == '$var' and scope == ['top', 'axi'] and fields[4] in signals:
                codes[fields[3]] = fields[4]
            elif head == '$enddefinitions':
                if set(codes.values()) != set(signals):
                    raise ValueError('Missing B-channel VCD variables')
                data = True
        elif head.startswith('#'):
            sample_step()
        elif head[0] in 'bB' and len(fields) == 2 and fields[1] in codes:
            changes[codes[fields[1]]] = head[1:].lower()
        elif head[0] in '01xXzZ' and head[1:] in codes:
            changes[codes[head[1:]]] = head[0].lower()
    sample_step()
    if held is not None:
        raise ValueError('B response remains stalled at end of wave')
    return totals


if __name__ == '__main__':
    for filename in sys.argv[1:]:
        path = Path(filename)
        totals = check(path)
        print(path.name, ' '.join('{}={}'.format(name, value) for name, value in totals.items()))
        if totals['handshakes'] != 64 or totals['hold_errors']:
            sys.exit(1)
