#!/usr/bin/env python3
"""Build/run standalone core coverage and real-memory assembly programs."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import re

from core_cases import cases
from rv32 import image_files

ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
BUILD=HERE/'build'/'core'


def run(command, log):
    result=subprocess.run([str(x) for x in command],cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.parent.mkdir(parents=True,exist_ok=True)
    log.write_text(result.stdout)
    if result.returncode:
        print(result.stdout[-12000:])
        raise RuntimeError(f'command failed ({result.returncode}); full log: {log}')
    return result.stdout


def build(top, standalone, waves, config=None):
    tag=top+('_standalone' if standalone else '_hierarchy')+('_waves' if waves else '')
    obj=BUILD/tag
    cmd=[os.environ.get('VERILATOR','verilator'),'--binary','--timing','--assert','--coverage-line',
         '-Wno-fatal','-Wno-MODDUP','-Wno-TIMESCALEMOD','--top-module',top,'--Mdir',obj,'-j','4',
         '-I'+str(ROOT/'src'),'-I'+str(ROOT/'src/alu'),'-I'+str(ROOT/'src/memory')]
    if standalone: cmd += ['+define+CORE_STANDALONE',HERE/'core_test_memory.sv']
    elif config:
        cmd += [f'-G{name}={value}' for name,value in config.items()]
    if waves: cmd += ['--trace']
    cmd += [ROOT/'src/core.sv',HERE/(top+'.sv')]
    print('Building '+tag,flush=True)
    run(cmd,BUILD/(tag+'.build.log'))
    return obj/('V'+top)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite',choices=['all','standalone','programs'],default='all')
    parser.add_argument('--program',type=Path,help='run one assembly source with the real hierarchy')
    parser.add_argument('--stop',help='stop label or byte PC for --program (default: pass/done/end)')
    parser.add_argument('--waves',action='store_true')
    parser.add_argument('--max-cycles',type=int,default=2000000)
    parser.add_argument('--l1-size',type=int,default=64*1024)
    parser.add_argument('--l2-size',type=int,default=256*1024)
    parser.add_argument('--l1-ways',type=int,default=4)
    parser.add_argument('--l2-ways',type=int,default=4)
    parser.add_argument('--l1-latency',type=int,default=1)
    parser.add_argument('--l2-latency',type=int,default=5)
    parser.add_argument('--dram-latency',type=int,default=80)
    args=parser.parse_args()
    BUILD.mkdir(parents=True,exist_ok=True)
    run([sys.executable,HERE/'test_rv32.py'],BUILD/'assembler_tests.log')
    print('PASS: assembler/reference known-answer tests')
    coverage=[]
    metrics=[]
    if args.suite in ('all','standalone') and not args.program:
        binary=build('tb_core_directed',True,args.waves)
        cov=BUILD/'directed.dat'
        output=run([binary,'+verilator+coverage+file+'+str(cov)],BUILD/'directed.log')
        if 'PASS: tb_core_directed' not in output: raise RuntimeError('directed test did not pass')
        print(output.strip())
        coverage.append(cov)
        binary=build('tb_core_program',True,args.waves)
        for name,source in cases():
            path=BUILD/(name+'.s'); path.write_text(source)
            for i_delay,d_delay,jitter in ((0,0,0),(1,5,1),(7,2,1)):
                simulate(binary,path,f'{name}_i{i_delay}_d{d_delay}',args,coverage,i_delay,d_delay,jitter,metrics)
    if args.suite in ('all','programs') or args.program:
        config={'L1_CACHE_SIZE':args.l1_size,'L2_CACHE_SIZE':args.l2_size,
                'L1_NUM_WAYS':args.l1_ways,'L2_NUM_WAYS':args.l2_ways,
                'L1_LATENCY':args.l1_latency,'L2_LATENCY':args.l2_latency,
                'DRAM_LATENCY':args.dram_latency}
        binary=build('tb_core_program',False,args.waves,config)
        programs=[args.program.resolve()] if args.program else sorted((ROOT/'assembly_files').glob('*.s'))
        if not programs: raise RuntimeError('no assembly_files/*.s sources found')
        for path in programs:
            simulate(binary,path,'real_'+path.stem,args,coverage,metrics=metrics)
    if coverage:
        merged=BUILD/'coverage.dat'
        run(['verilator_coverage','--write',merged,*coverage],BUILD/'coverage_merge.log')
        run(['verilator_coverage','--write-info',BUILD/'coverage.info',merged],BUILD/'coverage_info.log')
        run(['verilator_coverage','--annotate',BUILD/'annotated','--annotate-all','--annotate-min','1',merged],BUILD/'coverage_annotate.log')
        report_coverage(BUILD/'coverage.info')
    if metrics:
        metrics_path=BUILD/'ipc.csv'
        columns=('run','program','retired','cycles','ipc','i_wait','d_wait',
                 'load_use_stalls','fifo_empty_cycles','fifo_full_cycles',
                 'branch_flush_cycles','execute_busy_cycles',
                 'branches','branch_taken','branch_predictions',
                 'branch_mispredictions','redirects')
        metrics_path.write_text(','.join(columns)+'\n' +
                                ''.join(','.join(str(row[key]) for key in columns)+'\n' for row in metrics))
        print('IPC results:',metrics_path)
    print('PASS: requested core suites')
    print('Next issues: misaligned-access/trap policy; sustained fetch throughput; broader ISA compliance.')


def simulate(binary,path,name,args,coverage,i_delay=0,d_delay=0,jitter=0,metrics=None):
    image,trace,stores,nt,ns,pc,regs,memory=image_files(path,BUILD/'images',args.stop if args.program else None)
    # Independently handwritten anchors for existing example programs.
    anchors={'program1':{6:19,7:5,8:4,9:15,10:11,11:128,12:64,13:0xfffffffc,18:19,19:4},
             'program3':{7:0x3000,10:12,11:2,12:7,13:5,14:32},
             'program4':{3:17,6:34,7:35,9:40},'program5':{9:8,10:9,11:11},
             'program6':{7:35,8:35,9:34,10:39},'program7':{10:14,11:14,12:17},
             'program8':{1:45,2:6,3:6},'program9':{1:1000,2:0,3:1},
             'program10':{1:1000,2:0,5:1,6:1},
             'program11':{1:1000,2:2000,3:3000,5:5000,6:6000,7:7000,8:8000,10:0}}
    if path.parent==ROOT/'assembly_files':
        for r,value in anchors.get(path.stem,{}).items():
            if regs[r]!=value: raise RuntimeError(f'reference disagrees with handwritten {path.stem} x{r}={value}, got {regs[r]}')
    cov=BUILD/(name+'.dat')
    cmd=[binary,f'+image={image}',f'+trace={trace}',f'+stores={stores}',f'+trace_count={nt}',f'+store_count={ns}',
         f'+stop_pc={pc}',f'+max_cycles={args.max_cycles}',f'+i_delay={i_delay}',f'+d_delay={d_delay}',f'+jitter={jitter}',
         '+verilator+coverage+file+'+str(cov)]
    if args.waves: cmd += [f'+waves={BUILD/(name+".vcd")}']
    print('Running '+name,flush=True)
    output=run(cmd,BUILD/(name+'.log'))
    if 'PASS: tb_core_program' not in output: raise RuntimeError(name+' missing PASS')
    pass_line=next(line for line in output.splitlines() if line.startswith('PASS:'))
    print(pass_line)
    match=re.search(r'retired=(\d+) .* cycles=(\d+) IPC=([0-9.]+).*I-wait=(\d+) D-wait=(\d+) load-use-stalls=(\d+) FIFO-empty=(\d+) FIFO-full=(\d+) branch-flush=(\d+) EX-busy=(\d+) branches=(\d+) branch-taken=(\d+) branch-predictions=(\d+) branch-mispredictions=(\d+) redirects=(\d+)',pass_line)
    if match and metrics is not None:
        (retired,cycles,ipc,i_wait,d_wait,load_use_stalls,fifo_empty_cycles,
         fifo_full_cycles,branch_flush_cycles,execute_busy_cycles,branches,
         branch_taken,branch_predictions,branch_mispredictions,redirects)=match.groups()
        metrics.append({'run':name,'program':path.stem,'retired':retired,'cycles':cycles,'ipc':ipc,
                        'i_wait':i_wait,'d_wait':d_wait,
                        'load_use_stalls':load_use_stalls,
                        'fifo_empty_cycles':fifo_empty_cycles,
                        'fifo_full_cycles':fifo_full_cycles,
                        'branch_flush_cycles':branch_flush_cycles,
                        'execute_busy_cycles':execute_busy_cycles,
                        'branches':branches,'branch_taken':branch_taken,
                        'branch_predictions':branch_predictions,
                        'branch_mispredictions':branch_mispredictions,
                        'redirects':redirects})
    coverage.append(cov)


def report_coverage(path):
    current=False
    lines=[]; branches=[]
    for line in path.read_text().splitlines():
        if line.startswith('SF:'): current=Path(line[3:]).name=='core.sv'
        elif current and line.startswith('DA:'):
            number,hits=map(int,line[3:].split(',')[:2]); lines.append((number,hits))
        elif current and line.startswith('BRDA:'):
            number,block,branch,hits=line[5:].split(','); branches.append((number,hits))
    hit=sum(h>0 for _,h in lines)
    print(f'core.sv line coverage: {hit}/{len(lines)} ({100*hit/max(len(lines),1):.2f}%)')
    missing=[n for n,h in lines if not h]
    if missing: print('Uncovered lines:',missing)
    if branches: print(f'core.sv branch coverage: {sum(h not in ("0","-") for _,h in branches)}/{len(branches)}')
    print('Coverage:',path,'; annotated source:',BUILD/'annotated/core.sv')


if __name__=='__main__':
    try: main()
    except (RuntimeError,ValueError,FileNotFoundError) as error:
        print('FAIL:',error,file=sys.stderr)
        sys.exit(1)
