#!/usr/bin/env python3
"""Join measured cycle counts with synthesis area and estimated CTS timing."""
import argparse
import csv
import json
from pathlib import Path
import re
import sys

PARAMETERS = ('ROB_ENTRIES', 'PHYS_REGS', 'INT_ENTRIES',
              'MUL_ENTRIES', 'DIV_ENTRIES', 'MEM_ENTRIES')
DEFAULT = (32, 64, 8, 4, 2, 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recommendations', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    recommendations = json.loads(args.recommendations.read_text())
    selected = tuple(recommendations['selected'][p] for p in PARAMETERS)
    cycles = {tuple(r['configuration'][p] for p in PARAMETERS): r
              for r in recommendations['configurations']}
    physical = {}
    for path in sorted(args.artifacts.rglob('summary.json')):
        report = json.loads(path.read_text())
        if report.get('design') != 'riscv_ooo' or 'synthesis' not in report:
            continue
        tag = Path(report['work']).name
        match = re.fullmatch(r'r(\d+)_p(\d+)_i(\d+)_m(\d+)_d(\d+)_l(\d+)', tag)
        config = tuple(map(int, match.groups())) if match else {
            'ooo_default': DEFAULT, 'ooo_selected': selected}.get(tag)
        if config in cycles and (config not in physical or 'cts' in report):
            physical[config] = report
    rows = []
    best_cycles = min(r['aggregate_cycles'] for r in cycles.values())
    fastest = min(cycles.values(), key=lambda r: r['aggregate_cycles'])
    for config, report in physical.items():
        measured = cycles[config]
        row = {**dict(zip(PARAMETERS, config)),
               'cycles': measured['aggregate_cycles'], 'ipc': measured['ipc'],
               'area_um2': report['synthesis']['area_um2'],
               'cells': report['synthesis']['cell_count'],
               'within_2_percent': measured['aggregate_cycles'] <= best_cycles * 1.02,
               'cts_available': 'cts' in report,
               'setup_slack_ns': report.get('cts', {}).get('setup_slack_ns', ''),
               'hold_slack_ns': report.get('cts', {}).get('hold_slack_ns', ''),
               'timing_accepted': 'cts' in report and report.get('accepted', False)}
        row['area_cycle_product'] = row['area_um2'] * row['cycles']
        row['regressions_over_5_percent'] = {
            name: 100 * (count / fastest['runs'][name] - 1)
            for name, count in measured['runs'].items()
            if count > fastest['runs'][name] * 1.05}
        rows.append(row)
    rows.sort(key=lambda r: r['area_um2'])
    for row in rows:
        row['pareto'] = not any(
            other['area_um2'] <= row['area_um2'] and other['cycles'] <= row['cycles'] and
            (other['area_um2'] < row['area_um2'] or other['cycles'] < row['cycles'])
            for other in rows)
    missing = [dict(zip(PARAMETERS, config)) for config in cycles if config not in physical]
    eligible = [r for r in rows if r['within_2_percent']]
    timing_eligible = [r for r in eligible if r['timing_accepted']]
    acceptance_errors = []
    if missing:
        acceptance_errors.append('Physical synthesis evidence is missing for capacity configurations.')
    if not timing_eligible:
        acceptance_errors.append('No configuration within 2% of the best aggregate cycle count has clean CTS timing evidence.')
    result = {
        'complete': not missing, 'missing_physical_results': missing,
        'accepted': not acceptance_errors, 'acceptance_errors': acceptance_errors,
        'selection_rule': 'Minimum measured synthesis area among configurations within 2% of best aggregate cycles with clean CTS timing; per-run regressions above 5% flagged.',
        'timing_basis': 'CTS uses estimated placement parasitics, not signoff extraction.',
        'minimum_area': min(rows, key=lambda r: r['area_um2']) if rows else None,
        'minimum_cycles': min(rows, key=lambda r: (r['cycles'], r['area_um2'])) if rows else None,
        'balanced': min(timing_eligible, key=lambda r: r['area_um2']) if timing_eligible else None,
        'area_candidate_within_2_percent': min(eligible, key=lambda r: r['area_um2']) if eligible else None,
        'minimum_area_cycle_product': min(rows, key=lambda r: r['area_cycle_product']) if rows else None,
        'candidates': rows,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    if rows:
        columns = [k for k in rows[0] if k != 'regressions_over_5_percent']
        with (args.output / 'comparison.csv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=columns, extrasaction='ignore')
            writer.writeheader()
            writer.writerows(rows)
    text = ['# Measured physical sizing comparison', '', result['selection_rule'], '',
            result['timing_basis'], '',
            f'Physical results: {len(rows)}/{len(cycles)} configurations. Conclusions are provisional when results are incomplete.', '',
            '| ROB/PRF/INT/MUL/DIV/MEM | Cycles | IPC | Synthesis area (µm²) | Cells | Setup slack (ns) | Hold slack (ns) | Pareto |',
            '|---|---:|---:|---:|---:|---:|---:|---|']
    for row in rows:
        capacity = '/'.join(str(row[p]) for p in PARAMETERS)
        text.append(f'| {capacity} | {row["cycles"]} | {row["ipc"]:.6f} | {row["area_um2"]:.2f} | {row["cells"]} | {row["setup_slack_ns"]} | {row["hold_slack_ns"]} | {row["pareto"]} |')
    for label in ('minimum_area', 'minimum_cycles', 'balanced', 'area_candidate_within_2_percent', 'minimum_area_cycle_product'):
        row = result[label]
        if row:
            text += ['', f'{label}: {dict((p, row[p]) for p in PARAMETERS)}, area {row["area_um2"]:.2f}µm², cycles {row["cycles"]}, IPC {row["ipc"]:.6f}.',
                     f'Per-run regressions above 5%: {len(row["regressions_over_5_percent"])}. CTS timing accepted: {row["timing_accepted"]}.']
    if acceptance_errors:
        text += ['', 'Acceptance failed: ' + ' '.join(acceptance_errors)]
    (args.output / 'comparison.md').write_text('\n'.join(text) + '\n')
    print(args.output / 'comparison.md')
    if missing:
        print(f'FAIL: missing physical synthesis evidence for {len(missing)}/{len(cycles)} capacity configurations; comparison is incomplete.', file=sys.stderr)
        for config in missing:
            print('  ' + ' '.join(f'{p}={config[p]}' for p in PARAMETERS), file=sys.stderr)
    else:
        print(f'PASS: measured physical evidence for all {len(cycles)} capacity configurations')
    if not timing_eligible:
        print('FAIL: no configuration within 2% of best aggregate cycles has clean CTS timing; balanced remains unset.', file=sys.stderr)
    return 0 if result['accepted'] else 1


if __name__ == '__main__':
    sys.exit(main())
