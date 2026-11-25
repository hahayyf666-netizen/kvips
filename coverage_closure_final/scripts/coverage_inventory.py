#!/usr/bin/env python
"""Extract comparable holes from VCS O-2018.09 URG text reports."""
from __future__ import print_function

import csv
import re
import sys
from collections import Counter, namedtuple
from pathlib import Path


Hit = namedtuple('Hit', 'module path line metric text detail covered evidence')
ROOT = 'axi4/examples/uvm_dut/tb/'
PATHS = {
    'top': ROOT + 'top.sv',
    'axi4_if': 'axi4/sv/if/axi4_if.sv',
    'axi4_ram_slave': ROOT + 'dut/axi4_ram_slave.sv',
    'sva': 'axi4/sv/assertions/axi4_if_sva.svh',
    'monitor': 'axi4/sv/uvm/axi4_monitor.svh',
}
SECTION = re.compile(r'^(Line|Cond|Toggle|Branch) Coverage for Module : (\w+)\s*$', re.M)
CHECKS = {'Line': 'LINE', 'Cond': 'CONDITION', 'Toggle': 'TOGGLE', 'Branch': 'BRANCH'}
LINE_ROW = re.compile(r'^(\d+(?:\.\d+)?)\s+(\d+)/(\d+)\s+(?:==>\s*)?(\S.*)$')
BITS_ROW = re.compile(r'^([\w$]+)(?:\[(\d+)(?::(\d+))?\])?\s+(?:Yes|No)\s+'
                      r'(Yes|No)\s+(?:T[0-9, T]*\s+)?(Yes|No)\b')
LOGIC_ROW = re.compile(r'^\s*(\d+)\s+([01xXzZ\- ]+?)\s+(Not Covered|Covered)\b')
BRANCH_ROW = re.compile(r'^([01xXzZ\- ]+?)\s+(Not Covered|Covered)\b')


def relative(path):
    return 'axi4/' + path.split('/axi4/', 1)[1] if '/axi4/' in path else path


def sig_line(source, path, signal):
    for number, line in enumerate((source / path).read_text().splitlines(), 1):
        if re.search(r'\b' + signal + r'\b', line.split('//', 1)[0]) and re.search(
                r'^\s*(?:input|output|inout|logic|wire|bit|int unsigned)\b', line):
            return str(number)
    return '—'


def extract_code(report, source):
    body = (report / 'modinfo.txt').read_text()
    sections = list(SECTION.finditer(body))
    ratio_pattern = {'Line': r'^TOTAL\s+(\d+)\s+(\d+)', 'Cond': r'^Conditions\s+(\d+)\s+(\d+)',
                     'Toggle': r'^Total Bits\s+(\d+)\s+(\d+)', 'Branch': r'^Branches\s+(\d+)\s+(\d+)'}
    hits = []
    for section in sections:
        kind, module = section.groups()
        block = re.split(r'\n-{20,}', body[section.end():], maxsplit=1)[0]
        path = PATHS['sva' if module == 'axi4_if' and kind in ('Cond', 'Branch') else module]
        metric = CHECKS[kind]
        total, covered = map(int, re.search(ratio_pattern[kind], block, re.M).groups())
        line_no, cond_id, expr = '', '', ''
        marker_lines = {}
        rows = []
        for row in block.splitlines():
            if row.startswith('FILE: '):
                path = relative(row[6:].strip())
            if kind == 'Line':
                match = LINE_ROW.match(row)
                if not match:
                    continue
                number, count, goal, text = match.groups()
                if '.' not in number and re.search(r'^' + number + r'\.\d+\s+\d+/\d+', block, re.M):
                    continue
                for index in range(int(goal)):
                    rows.append(Hit(module, path, number, metric, text, 'line-bin '+str(index+1),
                                    index < int(count), 'modinfo.txt'))
            if kind == 'Cond':
                if row.startswith(' LINE '):
                    line_no = row.split()[-1]
                if row.startswith(' CONDITION_ID '):
                    cond_id = row.split()[-1]
                if re.match(r'^ (SUB-)?EXPRESSION ', row):
                    expr = row.split('EXPRESSION ', 1)[1]
                match = LOGIC_ROW.match(row)
                if match:
                    vector_id, vector, status = match.groups()
                    rows.append(Hit(module, path, line_no, metric, expr,
                                    'c{} v{} {}'.format(cond_id, vector_id, ''.join(vector.split())),
                                    status == 'Covered', 'modinfo.txt'))
            if kind == 'Toggle':
                match = BITS_ROW.match(row)
                if match:
                    name, upper, lower, down, up = match.groups()
                    if module == 'axi4_if':
                        path = PATHS['sva' if name.startswith('kvips_') else module]
                    number = sig_line(source, path, name)
                    if upper is None:
                        names = [name]
                    else:
                        high, low = int(upper), int(lower if lower is not None else upper)
                        names = ['{}[{}]'.format(name, i) for i in range(low, high + 1)]
                    for signal in names:
                        rows.extend(Hit(module, path, number, metric, signal, direction, state == 'Yes',
                                        'modinfo.txt') for direction, state in [('1->0', down), ('0->1', up)])
            if kind == 'Branch':
                match = BRANCH_ROW.match(row)
                if match:
                    vector, status = match.groups()
                    pieces = vector.split()
                    last = max(i for i, v in enumerate(pieces, 1) if v != '-')
                    number, expression = marker_lines[last]
                    rows.append(Hit(module, path, number, metric, expression,
                                    'root {} [{}]'.format(marker_lines[1][0], ''.join(pieces)),
                                    status == 'Covered', 'modinfo.txt'))
                    continue
                statement = re.match(r'^(\d+)\s{2,}(\S.*)', row)
                if statement:
                    line_no, expr = statement.groups()
                    if len(marker_lines) > 0 and int(line_no) < int(marker_lines[1][0]):
                        marker_lines.clear()
                slot = re.match(r'^\s+-(\d+)-\s*$', row)
                if slot:
                    index = int(slot.group(1))
                    if index == 1:
                        marker_lines.clear()
                    marker_lines[index] = (line_no, expr)
        actual = (len(rows), sum(item.covered for item in rows))
        if actual != (total, covered):
            raise ValueError('{} {} text/detail total {} != {}'.format(module, metric, actual, (total, covered)))
        hits.extend(rows)
    return hits


def extract_assertions(report, source):
    contents = (report / 'asserts.txt').read_text()
    block = contents.split('Assertions Uncovered:', 1)[1].split('Assertions Without Attempts:', 1)[0]
    for name, attempts, successes, failures, incomplete in re.findall(
            r'^((?:top\.axi|uvm_pkg)\..+?)\s+0\s+0\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$', block, re.M):
        module = 'axi4_if' if name.startswith('top.axi.') else 'uvm_pkg'
        path = PATHS['sva'] if module == 'axi4_if' else 'VCS/UVM library source'
        line = '—'
        if module == 'axi4_if':
            lines = (source / path).read_text().splitlines()
            label = name.rsplit('.', 1)[1]
            line = str(next(i for i, content in enumerate(lines, 1) if content.startswith(label + ':')))
        yield Hit(module, path, line, 'ASSERTION', name, 'nonvacuous success', int(successes) > 0,
                  'asserts.txt')


def extract_groups(report, source):
    contents = (report / 'grpinfo.txt').read_text().split('\nGroup Instance : ', 1)[0]
    blocks = re.split(r'\nSummary for (?:Variable|Cross) (\w+)\s*\n', contents)
    for index in range(1, len(blocks), 2):
        name, body = blocks[index:index+2]
        if 'Uncovered bins' not in body and 'Element holes' not in body:
            continue
        path = PATHS['monitor']
        lines = (source / path).read_text().splitlines()
        line = str(next(i for i, row in enumerate(lines, 1) if row.strip().startswith(name + ':')))
        if name == 'cx_write_resp' and 'Element holes' in body:
            table = body.split('Element holes', 1)[1].split('Covered bins', 1)[0]
            match = re.search(r'^\*\s+\[([^]]+)\]\s+--\s+--\s+4\s*$', table, re.M)
            if match is None:
                raise ValueError('Unexpected compressed response cross')
            for write in (0, 1):
                for resp in match.group(1).split(','):
                    yield Hit('axi4_monitor.cov', path, line, 'FUNCTIONAL', name,
                              'is_write={} x {}'.format(write, resp.strip()), False, 'grpinfo.txt')
            continue
        table = body.split('Uncovered bins', 1)[1].split('Covered bins', 1)[0]
        for row in table.splitlines():
            match = re.match(r'^(\S+)\s+0\s+\d+\s+', row)
            if match:
                yield Hit('axi4_monitor.cov', path, line, 'FUNCTIONAL', name, match.group(1), False, 'grpinfo.txt')


def parse(report, source):
    return extract_code(report, source) + list(extract_assertions(report, source)) + list(extract_groups(report, source))


def classification(hit):
    module, path, line, metric, expr, detail, _, evidence = hit
    priority = 'Medium'
    code, reach, why, test = 'F', 'Unknown', '需要按引用行及原始 URG 表检查触发状态。', '保留缺口'
    if metric == 'FUNCTIONAL':
        code, reach, why, test = 'E', 'Unreachable', 'RAM 只发 OKAY 或 DECERR，未实现独占应答和 SLVERR。', '在支持该响应的 DUT 或 responder 验证'
    elif metric == 'ASSERTION':
        if 'known_' in expr:
            code, reach, why, test = 'D', 'Reachable', '可选 X/Z 检查默认关闭。', 'BREADY 专项启用 KVIPS_AXI4_ASSERT_KNOWN'
        elif 'aw_excl' in expr:
            code, why, test = 'F', 'RAM 无独占监视器，已有 LOCK 属性测试只发锁定读。', '用支持独占的 DUT 验证匹配的独占读写'
        else:
            code, why, test = 'F', 'UVM 库定义断言，当前层级无尝试。', '保留库定义统计，按实例报告项目 SVA'
    elif module == 'top' and metric != 'TOGGLE':
        code, reach, why, test = 'D', 'Reachable', '默认未启用已存在的信号跟踪与波形输出。', 'BREADY 专项加 DUT_DEBUG、KVIPS_WAVES'
        if metric == 'CONDITION' and line == '47' and detail.endswith('0010'):
            code, reach, why = 'E', 'Unreachable', 'RAM 仅在 rd_active 时置 RVALID；终拍握手同时清除两者。'
        if metric == 'CONDITION' and line == '47' and detail.endswith('0001'):
            code, reach, why, test = 'C', 'Reachable', '当前读驱动在请求处理时才保持 RREADY，未观察到三个读状态都为 0 时单独预置 RREADY。', '有空闲 READY 目标的测试可显式配置提前就绪'
    elif module == 'axi4_ram_slave' and metric == 'CONDITION':
        if line == '169':
            code, reach, why, test = 'E', 'Unreachable', '首个非末 W beat 同步置 active=1、WREADY=0、count=3；count 清零时同步恢复 WREADY。', '查 RAM 153–206 的 NBA 状态更新'
        else:
            code, reach, why, test = 'F', 'Unreachable', '合法 WLAST 与末拍相等；缺失两种组合需要协议故障注入。', '已有 Missing/Premature WLAST 独立证据'
    elif module == 'axi4_ram_slave' and metric == 'LINE':
        code, reach, why, test = 'E', 'Unreachable', ('合法 burst 排除保留编码 3。' if line == '109' else 'LEN+1 与 1<<SIZE 皆非零，合法 WRAP 的 total 不为 0。'), '保留在原始分母'
    elif module == 'axi4_if' and metric in ('CONDITION', 'LINE', 'BRANCH'):
        if line == '401':
            code, reach, why, test = 'D', 'Reachable', '只有显式关闭接口断言，复位后方可进入该布尔组合。', '保留正向回归断言使能'
        elif line in ('403', '406', '407'):
            code, reach, why, test = 'C', 'Reachable', '现有 top 只做初始复位，未在建立队列后复位。', '未来用独立 reset-in-flight 驱动及恢复验证'
        elif 'EXOKAY' in expr or line in ('461', '462', '491', '492'):
            code, reach, why, test = 'E', 'Unreachable', '本 RAM 响应逻辑只产生 OKAY/DECERR。', '独占 responder 或支持独占的 DUT'
        elif line in ('423', '424'):
            code, reach, why, test = 'E', 'Unreachable', '当前 RAM 在 AW 握手前 WREADY 保持 0。', '独立 Checker-only Early-W responder'
        else:
            code, reach, why, test = 'F', 'Unreachable', '该分支需要 LAST/计数/ID/通道顺序违反当前 RAM 的合法事务不变量。', '检查已有 fault injection 或在专用 checker bench 验证'
    elif metric == 'TOGGLE':
        signal = expr.split('[')[0]
        if 'addr' in signal or signal.endswith('_len') or signal in ('awlen', 'arlen'):
            code, reach, why, test = 'A', 'Reachable', '此前合法地址窗口或 LEN 发起顺序未出现此位翻转。', '地址位行走/越界后回到映射区，或随机 LEN 穿插短包'
            priority = 'High'
        elif signal in ('bresp', 'rresp'):
            code, reach, why, test = 'A', 'Reachable', '旧用例取得 DECERR 后未用 OKAY 响应显式恢复两位。', 'DECERR→OKAY'
        elif signal in ('awuser', 'aruser', 'wr_user', 'rd_user', 'buser', 'ruser', 'awcache',
                        'arcache', 'awprot', 'arprot', 'awregion', 'arregion'):
            code, reach, why, test = 'A', 'Reachable', '边带字段未显式回到初值或旧激励只使用 0。', '合法 USER 和属性 0→有效值→0'
        elif signal.endswith('size'):
            code, reach, why, test = 'B', 'Unreachable', '64 位口最多 8 字节，SIZE 合法编码 0..3，bit 2 保持 0。', '更宽数据总线才适用'
        elif signal == 'areset_n':
            code, reach, why, test = 'C', 'Reachable', '初始复位由 X→0→1，现有驱动未再次拉低。', '未来设计复位中断与恢复专项'
        elif signal.startswith('kvips_'):
            code, reach, why, test = 'D', 'Unknown', '启动期静态开关，跨 test 的初值变化不等同于单次仿真边沿。', '按 SVA 尝试数复核开关效果'
        elif signal == 'wuser':
            code, why, test = 'F', '示例 DUT 未接 WUSER；主驱动中 WUSER 默认 0。', '需要明确的 WUSER 功能定义'
        elif signal == 'arlock':
            code, reach, why, test = 'A', 'Reachable', '锁定读已命中功能 bin，但旧 LOCK 测试仅有 1 次读，未在同次仿真中形成 0→1→0。', '普通读→锁定读→普通读属性测例'
        elif signal == 'awlock':
            code, reach, why, test = 'F', 'Unknown', '当前测试仅进行普通写，本 RAM 无独占监视器。', '在支持独占的目标上验证匹配读写'
    return code, reach, why, test, priority


def key(hit):
    return hit[:6]


def subconditions(expression):
    """Split the outer URG expression without flattening nested operands."""
    def depth_at_parentheses(text):
        depth = 0
        for index, char in enumerate(text):
            if char == '(':
                depth += 1
            elif char == ')':
                depth -= 1
            yield index, depth
    expression = expression.strip()
    while expression.startswith('(') and expression.endswith(')'):
        if next(index for index, depth in depth_at_parentheses(expression) if depth == 0) != len(expression)-1:
            break
        expression = expression[1:-1].strip()
    pieces, begin = [], 0
    for index, depth in depth_at_parentheses(expression):
        if depth == 0 and expression[index:index+2] in ('&&', '||'):
            pieces.append(expression[begin:index].strip())
            begin = index+2
        if depth == 0 and expression[index] == '?':
            return expression[:index].strip()
    pieces.append(expression[begin:].strip())
    return ' | '.join('{}: {}'.format(i+1, value) for i, value in enumerate(pieces))


def write_csv(path, columns, rows):
    with path.open('w', encoding='utf-8-sig', newline='') as handle:
        writer = csv.writer(handle)
        writer.writerow(columns)
        writer.writerows(rows)


def scoped(report, source, output, final_report=None, final_source=None):
    baseline = parse(report, source)
    final = parse(final_report, final_source) if final_report is not None else baseline
    final_keys = {key(item): item for item in final}
    for metric in CHECKS.values():
        if set(key(i) for i in final if i.metric == metric) != set(key(i) for i in baseline if i.metric == metric):
            raise ValueError('Coverage model changed for ' + metric)
    rows = []
    conditions = []
    for hit in baseline:
        end = final_keys.get(key(hit))
        if end is None and hit.metric == 'ASSERTION':
            raise ValueError('Unmatched assertion ' + str(hit))
        covered = end.covered if end is not None else True  # URG prints only missing functional bins.
        if hit.metric == 'CONDITION':
            conditions.append([hit.module, hit.path, hit.line, hit.text, subconditions(hit.text),
                               hit.detail, int(hit.covered), int(covered)])
        if hit.covered and not covered:
            raise ValueError('Lost coverage for ' + str(hit))
        if hit.covered:
            continue
        code, reach, reason, test, priority = classification(hit)
        if covered:
            reach = 'Reachable'
        rows.append([hit.module, hit.path, hit.line, hit.metric, hit.text, 'Covered' if covered else 'Not Covered',
                     hit.detail, code, reason, reach, test, priority, 'Fixed' if covered else 'Pending',
                     'reports/baseline/urg/raw/'+hit.evidence +
                     (' | reports/final/urg/raw/'+hit.evidence if final_report else '')])
    columns = ['Module', 'Source File', 'Line Number', 'Metric', 'Signal / Expression', 'Current Coverage',
               'Trigger Condition', 'Root Cause Class', 'Root Cause', 'Reachability', 'Proposed Test',
               'Priority', 'Status', 'Evidence']
    write_csv(output, columns, rows)
    write_csv(output.with_name(output.stem + '_CONDITION_VECTORS.csv'),
              ['Module', 'Source File', 'Line Number', 'Expression', 'Subconditions (URG column order)',
               'Vector', 'Baseline Hit', 'Current Hit'],
              conditions)
    print('Extracted', len(rows), 'baseline misses:', dict(Counter(row[3] for row in rows)))
    print('Classifications:', dict(Counter(row[7] for row in rows)))
    print('Statuses:', dict(Counter(row[12] for row in rows)))


if __name__ == '__main__':
    args = [Path(arg) for arg in sys.argv[1:]]
    if len(args) not in (3, 5):
        sys.exit('usage: coverage_inventory.py BASE_URG BASE_SOURCE OUTPUT_CSV [FINAL_URG FINAL_SOURCE]')
    scoped(*args)
