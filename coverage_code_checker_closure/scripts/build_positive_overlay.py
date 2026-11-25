#!/usr/bin/env python3
"""Create the small positive-test patch and its transport overlay."""
import argparse
import difflib
import io
import tarfile
from pathlib import Path


TB = Path('axi4/examples/uvm_dut/tb')


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Unexpected base source: ' + old)
    return text.replace(old, new)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('source', type=Path)
    p.add_argument('stage', type=Path)
    p.add_argument('overlay', type=Path)
    args = p.parse_args()
    top = TB / 'top.sv'
    pkg = TB / 'tb_pkg.sv'
    added = TB / 'axi4_dut_code_tests.svh'
    before = {p: (args.source / p).read_text() for p in (top, pkg)}
    after = {
        top: replace_once(before[top], '  logic areset_n;\n', '''  logic areset_n;
`ifndef VERILATOR
  uvm_event dut_reset_request = new("dut_reset_request");
`endif
'''),
        pkg: replace_once(before[pkg], '  `include "axi4_dut_fc_tests.svh"\n',
                          '''  `include "axi4_dut_fc_tests.svh"
`ifndef VERILATOR
  `include "axi4_dut_code_tests.svh"
`endif
'''),
        added: (args.stage / 'source' / 'added_tests' / added.name).read_text(),
    }
    after[top] = replace_once(after[top], '    areset_n = 1;\n  end\n', '''    areset_n = 1;
`ifndef VERILATOR
    forever begin
      dut_reset_request.wait_trigger();
      @(negedge aclk);
      areset_n = 0;
      repeat (2) @(negedge aclk);
      areset_n = 1;
    end
`endif
  end
''')
    after[top] = replace_once(after[top], '    run_test();\n', '''`ifndef VERILATOR
    uvm_config_db#(uvm_event)::set(null, "*", "dut_reset_request", dut_reset_request);
`endif
    run_test();
''')
    patch = args.stage / 'source' / 'patches' / 'positive-tests.patch'
    patch.parent.mkdir(parents=True, exist_ok=True)
    with patch.open('w', encoding='utf-8', newline='\n') as diff, tarfile.open(args.overlay, 'w:gz') as archive:
        for path, content in after.items():
            path_name = path.as_posix()
            diff.writelines(difflib.unified_diff(
                before.get(path, '').splitlines(keepends=True), content.splitlines(keepends=True),
                'a/' + path_name if path in before else '/dev/null', 'b/' + path_name))
            binary = content.encode('utf-8')
            entry = tarfile.TarInfo(path_name)
            entry.size = len(binary)
            archive.addfile(entry, io.BytesIO(binary))


if __name__ == '__main__':
    main()
