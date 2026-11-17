#!/usr/bin/env python3
"""Create the synthesis matrix and selected CTS arguments from measured sizing.

The simulation selection is provisional until physical synthesis provides area.
Every candidate is synthesized under identical constraints to expose area/cycle
tradeoffs instead of treating queue entry count as an area measurement.
"""
import argparse
import json
from pathlib import Path

DEFAULT = dict(ROB_ENTRIES=32, PHYS_REGS=64, INT_ENTRIES=8,
               MUL_ENTRIES=4, DIV_ENTRIES=2, MEM_ENTRIES=4)
AXES = dict(ROB_ENTRIES=(16, 32, 64), PHYS_REGS=(48, 64, 96),
            INT_ENTRIES=(4, 8, 12), MUL_ENTRIES=(2, 4, 8),
            DIV_ENTRIES=(1, 2, 4), MEM_ENTRIES=(2, 4, 8))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recommendations', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    recommendations = json.loads(args.recommendations.read_text())
    selected = recommendations['selected']
    if set(selected) != set(DEFAULT):
        raise ValueError('selected must provide all six uppercase capacity parameters')
    for key, value in selected.items():
        if not isinstance(value, int) or value not in AXES[key]:
            raise ValueError(f'invalid selected capacity {key}={value}')
    measured = recommendations.get('configurations')
    if not isinstance(measured, list) or not measured:
        raise ValueError('recommendations must include the measured configurations list')
    configs = [row.get('configuration', {}) for row in measured]
    unique = {}
    for config in configs:
        if set(config) != set(DEFAULT):
            raise ValueError('each measured configuration must provide all six uppercase capacity parameters')
        for key, value in config.items():
            if not isinstance(value, int) or value not in AXES[key]:
                raise ValueError(f'invalid measured capacity {key}={value}')
        unique.setdefault(tuple(config[k] for k in DEFAULT), config)
    selected_key = tuple(selected[k] for k in DEFAULT)
    if selected_key not in unique:
        raise ValueError('selected configuration is missing from the measured configurations')
    matrix = []
    for config in unique.values():
        tag = '_'.join(f'{short}{config[key]}' for short, key in
                       zip(('r', 'p', 'i', 'm', 'd', 'l'), DEFAULT))
        matrix.append({'tag': tag, 'overrides': ' '.join(f'{k}={v}' for k, v in config.items())})
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'asic_matrix.json').write_text(json.dumps({'include': matrix}) + '\n')
    (args.output / 'selected_overrides.txt').write_text(''.join(f'{k}={v}\n' for k, v in selected.items()))
    print(json.dumps({'include': matrix}))


if __name__ == '__main__':
    main()
