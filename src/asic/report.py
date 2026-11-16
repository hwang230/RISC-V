#!/usr/bin/env python3
"""Summarize real ORFS results and fail when the requested stage is incomplete.

Post-CTS parasitics are estimated from placement, not extracted routing.
"""
import argparse
import json
from pathlib import Path
import re
import sys


def summarize(work, design, stage):
    logs = work / 'logs/nangate45' / design / 'base'
    reports = work / 'reports/nangate45' / design / 'base'
    result = {'design': design, 'stage': stage, 'work': str(work),
              'timing_basis': 'post-CTS estimated placement parasitics; not signoff',
              'clock_period_ns': 10, 'minimum_input_delay_ns': 0,
              'cores': 4, 'hold_repair_enabled': True}
    synth = json.loads((logs / '1_synth.json').read_text())
    result['synthesis'] = {
        'area_um2': synth['synth__design__instance__area'],
        'cell_count': synth['synth__design__instance__count'],
        'warnings': synth.get('synth__flow__warnings__count', 0),
        'errors': synth.get('synth__flow__errors__count', 0),
    }
    stat = (reports / 'synth_stat.txt').read_text()
    dffs = {}
    for line in stat.splitlines():
        match = re.match(r'\s*(\d+)\s+\S+\s+\d+\s+\S+\s+((?:DFF|SDFF|DFFE)\w*)\s*$', line)
        if match:
            dffs[match[2]] = int(match[1])
    result['mapped_storage'] = {'flip_flops': sum(dffs.values()), 'cells_by_type': dffs,
                                'synth_stat': str(reports / 'synth_stat.txt')}
    warning_lines = set()
    inferred_arrays = {}
    for path in logs.glob('1*.log'):
        for line in path.read_text(errors='replace').splitlines():
            memory = re.match(r'Memory (.+) has dimensions (\d+) x (\d+) = (\d+)(.*)$', line)
            if memory:
                inferred_arrays[memory[1]] = {
                    'name': memory[1], 'entries': int(memory[2]),
                    'bits_per_entry': int(memory[3]), 'total_bits': int(memory[4]),
                    'rom': 'ROM' in memory[5],
                }
            if re.search(r'\bwarning\b', line, re.IGNORECASE) and not re.search(r'\b0 warnings?\b', line):
                warning_lines.add(line.strip())
    result['mapped_storage']['arrays_after_coarse_synthesis'] = sorted(inferred_arrays.values(), key=lambda a: a['name'])
    result['mapped_storage']['array_bits_after_coarse_synthesis'] = sum(a['total_bits'] for a in inferred_arrays.values())
    result['synthesis_warning_messages'] = sorted(warning_lines)
    errors = []
    if result['synthesis']['errors']:
        errors.append('synthesis reported errors')
    if stage == 'cts':
        cts = json.loads((logs / '4_1_cts.json').read_text())
        keys = {
            'area_um2': 'cts__design__instance__area',
            'cell_count': 'cts__design__instance__count',
            'setup_slack_ns': 'cts__timing__setup__ws',
            'hold_slack_ns': 'cts__timing__hold__ws',
            'setup_tns_ns': 'cts__timing__setup__tns',
            'hold_tns_ns': 'cts__timing__hold__tns',
            'setup_violations': 'cts__timing__drv__setup_violation_count',
            'hold_violations': 'cts__timing__drv__hold_violation_count',
        }
        result['cts'] = {name: cts[key] for name, key in keys.items()}
        result['cts']['hold_buffers'] = cts.get('cts__design__instance__count__hold_buffer', 0)
        for kind in ('setup', 'hold'):
            if result['cts'][f'{kind}_slack_ns'] < 0 or result['cts'][f'{kind}_tns_ns'] < 0 or result['cts'][f'{kind}_violations']:
                errors.append(f'{kind} timing failed')
        result['cts_report'] = str(reports / '4_cts_final.rpt')
        result['backend_paths_report'] = str(reports / '4_cts_backend_paths.rpt')
    result['acceptance_errors'] = errors
    result['accepted'] = not errors
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--design', default='riscv_ooo')
    parser.add_argument('--stage', choices=('synth', 'cts'), default='cts')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = summarize(args.work, args.design, args.stage)
    except (OSError, KeyError, ValueError) as error:
        print(f'FAIL: incomplete or invalid ORFS evidence: {error}', file=sys.stderr)
        return 1
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print(text, end='')
    return 0 if result['accepted'] else 1


if __name__ == '__main__':
    sys.exit(main())
