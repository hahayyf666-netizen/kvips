#!/usr/bin/env python3
"""Create an item-level inventory checked against URG's raw denominators."""
import argparse
import csv
import difflib
import importlib.util
import re
from collections import Counter
from pathlib import Path


SVA = 'axi4/sv/assertions/axi4_if_sva.svh'
DIAGNOSTICS = {
    423: 'w_without_aw', 424: 'w_without_aw',
    428: 'w_overflow', 429: 'w_overflow',
    431: 'missing_wlast', 432: 'missing_wlast',
    434: 'premature_wlast', 435: 'premature_wlast',
    442: 'premature_wlast', 443: 'premature_wlast',
    456: 'orphan_b', 457: 'orphan_b', 465: 'orphan_b',
    461: 'b_exokay_unlocked', 462: 'b_exokay_unlocked',
    478: 'orphan_r', 479: 'orphan_r',
    485: 'missing_rlast', 486: 'missing_rlast',
    488: 'premature_rlast', 489: 'premature_rlast',
    491: 'r_exokay_unlocked', 492: 'r_exokay_unlocked',
    494: 'r_overflow', 495: 'r_overflow',
}


def load_inventory(source):
    name = 'coverage_inventory'
    path = source / 'coverage_closure_final' / 'scripts' / (name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def classify(h):
    line = int(h.line.split('.')[0]) if h.line.split('.')[0].isdigit() else None
    expr = h.text
    if h.module == 'uvm_pkg':
        return 'G', 'Unknown', 'VCS UVM 库路径，当前组无尝试。', '按库项报告', 'Low'
    if h.metric == 'ASSERTION':
        return 'A', 'Reachable', 'RAM 口没有独占写支持，AWLOCK 属性转到隔离台架验证。', 'locked_ok_control', 'High'
    if h.metric == 'TOGGLE':
        if expr == 'areset_n':
            return 'C', 'Reachable', '仅初始复位，缺少运行期下降沿。', 'reset_aw / reset_b / reset_r', 'High'
        if expr in ('awlock', 'arlock'):
            return 'A', 'Reachable', '同次模拟缺少普通、锁定、普通请求。', ('locked_ok_control' if expr == 'awlock' else 'axi4_dut_arlock_toggle_test'), 'High'
        if 'size[2]' in expr:
            return 'F', 'Unreachable', '64-bit 接口的合法 SIZE 为 0..3。', '保留原始分母', 'Low'
        return 'E', 'Unreachable', '启动时固定，合法测试内无 1→0。', '保持配置并核对属性尝试', 'Low'
    if h.module == 'top':
        if h.detail.endswith('0001'):
            return 'A', 'Reachable', '缺少空闲时提前 RREADY。', 'axi4_dut_idle_rready_test', 'High'
        return 'F', 'Unreachable', 'RVALID 的置位以 rd_active 为前提，终拍一起清除。', '复核 RAM 读状态转换', 'Low'
    if h.module == 'axi4_ram_slave':
        if line == 169:
            return 'F', 'Unreachable', '非零 stall count 伴随 active=1、WREADY=0，恢复时同周期归零。', '审查同步状态转换', 'Low'
        if line == 192:
            return 'D', 'Unreachable', '在正向 RAM 中 WLAST 与最后一拍相等。', 'LAST 注入仅用于独立 Checker', 'Medium'
        why = 'LEN+1 和 1<<SIZE 非零。' if line == 102 else '合法 AWBURST/ARBURST 不含保留编码 3。'
        return 'F', 'Unreachable', why, '保留原始分母', 'Low'
    if line in (403, 406, 407):
        test = 'axi4_dut_reset_b_test' if line == 403 else 'axi4_dut_reset_r_test'
        return 'C', 'Reachable', '现有初始复位时队列为空，foreach 主体未执行。', test, 'High'
    if line == 401:
        return 'E', 'Unreachable', '缺口需要运行时关闭接口检查，当前范围保持使能。', '保留原始分母', 'Low'
    if line == 502:
        return 'B', 'Reachable', '同拍 AR 和前笔 RLAST 的两个 NBA 竞争，实际队列仍有请求而计数成零。', 'r_count_overlap_control', 'Medium'
    if line in (461, 491) and h.metric == 'CONDITION':
        if h.detail.endswith('011'):
            return 'E', 'Unreachable', '需禁用 EXOKAY 检查，当前范围保持使能。', '保留原始分母', 'Low'
        if h.detail.endswith(('10', '110')):
            return 'A', 'Reachable', 'RAM 只返回 OKAY/DECERR，锁定 EXOKAY 需要另一 responder。', 'locked_ok_control', 'Medium'
    if line in DIAGNOSTICS:
        why = '接口状态检查按 AW-first 建模，这条诊断取决于该实现约定。' if line in (423, 424) else '正常 RAM 事务不走该诊断分支。'
        return 'D', 'Reachable', why, DIAGNOSTICS[line], 'High'
    raise ValueError('Unclassified coverage hole: {}'.format(h))


def line_map(before, after):
    old = before.read_text().splitlines()
    new = after.read_text().splitlines()
    return {i + n + 1: j + n + 1 for i, j, length in
            difflib.SequenceMatcher(None, old, new, autojunk=False).get_matching_blocks()
            for n in range(length)}


def key(hit, top_map=None):
    line, detail = hit.line, hit.detail
    if top_map is not None and hit.module == 'top':
        head, sep, tail = line.partition('.')
        line = str(top_map.get(int(head), 0)) + sep + tail
        detail = re.sub(r'root (\d+)', lambda m: 'root ' + str(top_map.get(int(m[1]), 0)), detail)
    return hit.module, hit.path, line, hit.metric, hit.text, detail


def checker_code(inv, report, source):
    """Read only the identical axi4_if scope from a Checker-only URG report."""
    contents = (report / 'modinfo.txt').read_text()
    sections = [contents[m.start():m.end()] + re.split(r'\n-{20,}', contents[m.end():], maxsplit=1)[0]
                for m in inv.SECTION.finditer(contents) if m[2] == 'axi4_if']
    if len(sections) != 4:
        raise ValueError('Expected all four axi4_if metrics in ' + str(report))
    class InterfaceReport:
        def __truediv__(self, filename):
            if filename != 'modinfo.txt':
                raise ValueError('Expected modinfo.txt')
            return self

        def read_text(self):
            return ('\n' + '-' * 79 + '\n').join(sections)

    return inv.extract_code(InterfaceReport(), source)


def grouped_assertions(report):
    rows = {}
    for line in (report / 'asserts.txt').read_text().splitlines():
        match = re.match(r'^((?:top\.axi\.|uvm_pkg\.).+?)\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$', line)
        if match:
            rows[match[1]] = tuple(map(int, match.groups()[1:]))
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument('source', type=Path)
    p.add_argument('baseline', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--positive', type=Path)
    p.add_argument('--final-source', type=Path)
    p.add_argument('--checker', type=Path)
    args = p.parse_args()
    inv = load_inventory(args.source)
    code = inv.extract_code(args.baseline, args.source)
    base_assertions = list(inv.extract_assertions(args.baseline, args.source))
    holes = [h for h in code + base_assertions if not h.covered]
    positive = {}
    top_map = None
    if args.positive:
        final_source = args.final_source or args.source
        top = inv.PATHS['top']
        top_map = line_map(args.source / top, final_source / top)
        positive = {key(h): h.covered for h in inv.extract_code(args.positive, final_source)}
        missing = [h for h in code if h.covered and not positive.get(key(h, top_map))]
        if missing:
            raise ValueError('Baseline-covered items no longer matched: {}'.format(missing))
    pa = grouped_assertions(args.positive) if args.positive else {}
    checker = {}
    ca = {}
    if args.checker:
        checker = {key(h): h.covered for h in checker_code(inv, args.checker, args.final_source or args.source)
                   if h.module == 'axi4_if'}
        ca = grouped_assertions(args.checker)
    with args.output.open('w', encoding='utf-8-sig', newline='') as stream:
        out = csv.writer(stream)
        out.writerow(['Module', 'Source File', 'Line', 'Metric', 'Expression', 'Missing Condition',
                      'Reachability', 'Root Cause Class', 'Root Cause', 'Proposed Test', 'Priority', 'Status', 'Evidence'])
        status_counts = Counter()
        for h in holes:
            cls, reach, why, test, priority = classify(h)
            sources = ['reports/baseline/urg/all/' + h.evidence]
            status = 'Baseline hole'
            if args.positive:
                status = 'Open'
                if ((h.metric == 'ASSERTION' and pa.get(h.text, (0, 0))[1] > 0)
                        or positive.get(key(h, top_map))):
                    status = 'Hit in positive RAM'
                sources.append('reports/positive/urg/all/' + h.evidence)
            if args.checker and h.module == 'axi4_if':
                if ((h.metric == 'ASSERTION' and ca.get(h.text, (0, 0))[1] > 0)
                        or checker.get(key(h))):
                    status = ('Hit in positive RAM and Checker' if status == 'Hit in positive RAM'
                              else 'Hit in Checker-only')
                sources.append('reports/negative/urg/all/' + h.evidence)
            out.writerow([h.module, h.path, h.line, h.metric, h.text, h.detail, reach, cls, why,
                          test, priority, status, ' | '.join(sources)])
            status_counts[status] += 1
    print('Baseline holes:', dict(Counter(h.metric for h in holes)))
    print('Status:', dict(status_counts))


if __name__ == '__main__':
    main()
