#!/usr/bin/env python3
"""Exercise the shared elastic multiplier and the machine CSR bank."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = HERE / 'build' / 'ooo_units' / sys.platform


def run(command, log):
    result = subprocess.run([str(item) for item in command], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'{result.stdout[-12000:]}\nFull log: {log}')
    return result.stdout


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    obj = BUILD / 'obj'
    run([os.environ.get('VERILATOR', 'verilator'), '--binary', '--timing', '--assert',
         '-Wno-fatal', '-Wno-TIMESCALEMOD', '--top-module', 'tb_ooo_units',
         '--Mdir', obj, '-j', '4', '-I' + str(ROOT / 'src'), HERE / 'tb_ooo_units.sv'],
        BUILD / 'build.log')
    output = run([obj / 'Vtb_ooo_units'], BUILD / 'run.log')
    if 'PASS: tb_ooo_units' not in output:
        raise RuntimeError('OOO unit simulation exited without PASS')
    print(output, end='')


if __name__ == '__main__':
    main()
