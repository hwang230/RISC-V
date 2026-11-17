#!/usr/bin/env python3
"""Verify either backend against the ISA model; compare IPC and sweep capacities."""
import argparse
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from core_cases import cases as legacy_cases
from ooo_cases import cases as ooo_cases, with_trap_handler
from rv32 import assemble, image_files

ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
BUILD_ROOT=HERE/'build'/'core'
DEFAULTS={'ROB_ENTRIES':32,'PHYS_REGS':64,'INT_ENTRIES':8,'MUL_ENTRIES':4,'DIV_ENTRIES':2,'MEM_ENTRIES':4}
SWEEPS={'INT_ENTRIES':(4,8,12),'MUL_ENTRIES':(2,4,8),'DIV_ENTRIES':(1,2,4),
        'MEM_ENTRIES':(2,4,8),'ROB_ENTRIES':(16,32,64),'PHYS_REGS':(48,64,96)}
DELAYS=((0,0,0),(1,5,1),(7,2,1))


def run(command,log,cwd=ROOT):
    result=subprocess.run([str(x) for x in command],cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.parent.mkdir(parents=True,exist_ok=True)
    log.write_text(result.stdout)
    if result.returncode:
        print(result.stdout[-14000:])
        raise RuntimeError(f'command failed ({result.returncode}); full log: {log}')
    return result.stdout


def run_covered(command,log,run_dir):
    """Require fresh coverage from every successful simulation, on all versions."""
    run_dir.mkdir(parents=True,exist_ok=True)
    coverage=run_dir/'coverage.dat'
    if coverage.exists(): coverage.unlink()
    output=run(command,log,cwd=run_dir)
    if not coverage.is_file() or coverage.stat().st_size==0:
        raise RuntimeError(f'simulation produced no coverage; expected fresh nonempty {coverage}')
    return output,coverage


def tool(name):
    explicit=os.environ.get(name.upper())
    return explicit or shutil.which(name) or '/usr/local/bin/'+name


def build(top,standalone,waves,backend,build_dir,config=None):
    build_dir.mkdir(parents=True,exist_ok=True)
    tag=top+('_standalone' if standalone else '_hierarchy')+('_waves' if waves else '')+'_'+sys.platform
    obj=build_dir/tag
    # Verilator 5.020's generated --binary main never writes coverage. Use an
    # explicit timing loop and coverage write on every supported version.
    main=build_dir/(top+'_main.cpp')
    source=f'''#include "verilated.h"
#include "verilated_cov.h"
#include "V{top}.h"
#include <memory>

int main(int argc, char** argv) {{
    auto context = std::make_unique<VerilatedContext>();
    context->traceEverOn(true);
    context->commandArgs(argc, argv);
    auto top = std::make_unique<V{top}>(context.get());
    while (!context->gotFinish()) {{
        top->eval();
        if (!top->eventsPending()) break;
        context->time(top->nextTimeSlot());
    }}
    top->final();
    context->coveragep()->write("coverage.dat");
    return context->gotFinish() ? 0 : 1;
}}
'''
    if not main.exists() or main.read_text()!=source: main.write_text(source)
    cmd=[tool('verilator'),'--cc','--exe','--build','--timing','--assert','--coverage-line',
         '-Wno-fatal','-Wno-MODDUP','-Wno-TIMESCALEMOD','--top-module',top,'--Mdir',obj,'-j','4',
         '-I'+str(ROOT/'src'),'-I'+str(ROOT/'src/alu'),'-I'+str(ROOT/'src/memory')]
    # Verilator 5.020 must unroll array reset loops to preserve nonblocking
    # assignments. Budget iterations and AST nodes for backend storage and,
    # in hierarchy builds, cache metadata (including every way).
    memory=config or {}
    loop_sizes=[64]
    statement_sizes=[30000]
    if backend=='ooo':
        capacities=[memory.get(name,value) for name,value in DEFAULTS.items()]
        capacities.append(sum(memory.get(name,DEFAULTS[name]) for name in
                              ('INT_ENTRIES','MUL_ENTRIES','DIV_ENTRIES','MEM_ENTRIES')))
        loop_sizes.extend(capacities)
        statement_sizes.extend(128*capacity for capacity in capacities)
    if standalone: cmd += ['+define+CORE_STANDALONE',HERE/'core_test_memory.sv']
    else:
        geometries=((memory.get('L1_CACHE_SIZE',64*1024),memory.get('L1_NUM_WAYS',4)),
                    (memory.get('L2_CACHE_SIZE',256*1024),memory.get('L2_NUM_WAYS',4)))
        if any(size<=0 or ways<=0 for size,ways in geometries):
            raise ValueError('cache sizes and associativities must be positive')
        loop_sizes.extend(max(size//(64*ways),ways) for size,ways in geometries)
        statement_sizes.extend(128*(size//64) for size,_ in geometries)
    cmd += ['--unroll-count',str(max(loop_sizes)),'--unroll-stmts',str(max(statement_sizes))]
    if backend=='ooo': cmd += ['+define+OOO_BACKEND']
    if config: cmd += [f'-G{name}={value}' for name,value in config.items()]
    if waves: cmd += ['--trace']
    cmd += [ROOT/('src/ooo_core.sv' if backend=='ooo' else 'src/core.sv'),HERE/(top+'.sv'),main]
    print('Building '+backend+'/'+str(build_dir.relative_to(BUILD_ROOT))+'/'+tag,flush=True)
    run(cmd,build_dir/(tag+'.build.log'))
    return obj/('V'+top)


def write_csv(path,rows):
    path.parent.mkdir(parents=True,exist_ok=True)
    columns=list(dict.fromkeys(key for row in rows for key in row if not isinstance(row[key],(list,dict))))
    with path.open('w',newline='') as handle:
        writer=csv.DictWriter(handle,columns,extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)


def generated_programs(build_dir,backend,only=None):
    sources=list(legacy_cases())
    if backend=='ooo': sources += list(ooo_cases())
    paths=[]
    for name,source in sources:
        if only and name!=only: continue
        if backend=='ooo' and name=='illegal': source=with_trap_handler(source)
        path=build_dir/'sources'/(name+'.s')
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(source)
        paths.append(path)
    return paths


def simulate(binary,path,name,args,backend,build_dir,coverage,i_delay=0,d_delay=0,jitter=0):
    image,trace,stores,nt,ns,pc,regs,_=image_files(path,build_dir/'images',args.stop if args.program else None,machine=backend=='ooo')
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
    run_dir=build_dir/'runs'/name
    # The portable C++ main writes coverage.dat in its working directory;
    # isolate each run so coverage files do not overwrite one another.
    metrics_path=build_dir/(name+'.metrics.json')
    cmd=[binary,f'+image={image}',f'+trace={trace}',f'+stores={stores}',f'+trace_count={nt}',f'+store_count={ns}',
         f'+stop_pc={pc}',f'+max_cycles={args.max_cycles}',f'+i_delay={i_delay}',f'+d_delay={d_delay}',f'+jitter={jitter}',
         f'+metrics={metrics_path}']
    _,labels=assemble(path.read_text())
    for label in ('overlap_div','overlap_add','overlap_dep'):
        if label in labels: cmd += [f'+{label}_pc={labels[label]}']
    if backend=='ooo' and 'overlap_div' in labels and i_delay==0 and not name.startswith('real_'):
        cmd += ['+check_overlap=1']
    if args.waves: cmd += [f'+waves={build_dir/(name+".vcd")}']
    print('Running '+backend+'/'+name,flush=True)
    output,cov=run_covered(cmd,build_dir/(name+'.log'),run_dir)
    if 'PASS: tb_core_program' not in output: raise RuntimeError(name+' missing PASS')
    print(next(line for line in output.splitlines() if line.startswith('PASS:')))
    metrics=json.loads(metrics_path.read_text())
    metrics.update(backend=backend,run=name,program=path.stem,i_delay=i_delay,d_delay=d_delay,jitter=jitter)
    coverage.append(cov)
    return metrics


def run_backend(args,backend,config):
    build_dir=BUILD_ROOT/backend
    build_dir.mkdir(parents=True,exist_ok=True)
    coverage=[]
    metrics=[]
    if args.suite in ('all','standalone') and not args.program:
        if backend=='inorder' and not args.case:
            binary=build('tb_core_directed',True,args.waves,backend,build_dir)
            output,cov=run_covered([binary],build_dir/'directed.log',build_dir/'runs'/'directed')
            if 'PASS: tb_core_directed' not in output: raise RuntimeError('directed test did not pass')
            print(next(line for line in output.splitlines() if line.startswith('PASS: tb_core_directed')))
            coverage.append(cov)
        binary=build('tb_core_program',True,args.waves,backend,build_dir,config if backend=='ooo' else None)
        for path in generated_programs(build_dir,backend,args.case):
            for i_delay,d_delay,jitter in DELAYS:
                metrics.append(simulate(binary,path,f'{path.stem}_i{i_delay}_d{d_delay}',args,backend,build_dir,coverage,i_delay,d_delay,jitter))
    if args.suite in ('all','programs') or args.program:
        memory_config={'L1_CACHE_SIZE':args.l1_size,'L2_CACHE_SIZE':args.l2_size,
                       'L1_NUM_WAYS':args.l1_ways,'L2_NUM_WAYS':args.l2_ways,
                       'L1_LATENCY':args.l1_latency,'L2_LATENCY':args.l2_latency,'DRAM_LATENCY':args.dram_latency}
        if backend=='ooo': memory_config.update(config)
        binary=build('tb_core_program',False,args.waves,backend,build_dir,memory_config)
        programs=[args.program.resolve()] if args.program else sorted((ROOT/'assembly_files').glob('*.s'))
        if args.case: programs=[p for p in programs if p.stem==args.case]
        if not programs and not args.case: raise RuntimeError('no assembly_files/*.s sources found')
        for path in programs: metrics.append(simulate(binary,path,'real_'+path.stem,args,backend,build_dir,coverage))
    write_csv(build_dir/'ipc.csv',metrics)
    if coverage:
        merged=build_dir/'coverage.dat'
        run([tool('verilator_coverage'),'--write',merged,*coverage],build_dir/'coverage_merge.log')
        run([tool('verilator_coverage'),'--write-info',build_dir/'coverage.info',merged],build_dir/'coverage_info.log')
    print('IPC results:',build_dir/'ipc.csv')
    return metrics


def compare(rows):
    grouped={(row['backend'],row['run']):row for row in rows}
    comparisons=[]
    for backend,name in grouped:
        if backend!='inorder' or ('ooo',name) not in grouped or name.startswith('illegal_'): continue
        a,b=grouped[(backend,name)],grouped[('ooo',name)]
        if a['retired']!=b['retired']: raise RuntimeError(f'noncomparable retire counts for {name}')
        comparisons.append({'run':name,'program':a['program'],'retired':a['retired'],
                            'inorder_cycles':a['cycles'],'ooo_cycles':b['cycles'],
                            'inorder_ipc':a['ipc'],'ooo_ipc':b['ipc'],
                            'cycle_speedup':a['cycles']/b['cycles'],
                            'ooo_cycle_change_percent':100*(b['cycles']/a['cycles']-1)})
    write_csv(BUILD_ROOT/'ipc_comparison.csv',comparisons)
    if comparisons:
        total_a=sum(r['inorder_cycles'] for r in comparisons)
        total_b=sum(r['ooo_cycles'] for r in comparisons)
        total_retired=sum(r['retired'] for r in comparisons)
        print(f'Comparable aggregate: inorder IPC={total_retired/total_a:.6f}, OOO IPC={total_retired/total_b:.6f}, cycle speedup={total_a/total_b:.4f}x')
    return comparisons


def validate_combined(configurations,combined):
    """Check the independently selected capacities together before recommending."""
    best=min(configurations,key=lambda row:row['aggregate_cycles'])
    regressions={}
    fastest_regressions={}
    for name,cycles in combined['runs'].items():
        baseline=best['runs'][name]
        if cycles>baseline*1.05:
            regressions[name]={'cycles':cycles,'reference_cycles':baseline,
                               'regression_percent':100*(cycles/baseline-1)}
        fastest=min(row['runs'][name] for row in configurations)
        if cycles>fastest*1.05:
            fastest_regressions[name]={'cycles':cycles,'reference_cycles':fastest,
                                       'regression_percent':100*(cycles/fastest-1)}
    return {'best_measured_configuration':best['configuration'],
            'best_measured_aggregate_cycles':best['aggregate_cycles'],
            'combined_aggregate_cycles':combined['aggregate_cycles'],
            'aggregate_cycle_change_percent':100*(combined['aggregate_cycles']/best['aggregate_cycles']-1),
            'within_2_percent':combined['aggregate_cycles']<=best['aggregate_cycles']*1.02,
            'regressions_over_5_percent':regressions,
            'regressions_vs_fastest_run_over_5_percent':fastest_regressions}


def storage_proxy(config):
    """Estimate variable ROB, rename and issue-queue storage in bits."""
    rob=config['ROB_ENTRIES']
    phys=config['PHYS_REGS']
    rob_tag_width=max(1,(rob-1).bit_length())
    phys_tag_width=max(1,(phys-1).bit_length())
    iq=sum(config[name] for name in ('INT_ENTRIES','MUL_ENTRIES','DIV_ENTRIES','MEM_ENTRIES'))
    rob_bits=rob*(221+2*phys_tag_width)
    rename_and_register_bits=34*phys+64*phys_tag_width
    queue_bits=iq*(4+rob_tag_width+3*phys_tag_width)
    return rob_bits+rename_and_register_bits+queue_bits


def sweep(args,base_config):
    directory=BUILD_ROOT/'sizing'
    directory.mkdir(parents=True,exist_ok=True)
    configs=[dict(base_config)]
    for parameter,values in SWEEPS.items():
        for value in values:
            config={**base_config,parameter:value}
            if config not in configs: configs.append(config)
    results=[]
    all_rows=[]
    result_by_config={}

    def evaluate(config):
        key=tuple(config[name] for name in DEFAULTS)
        if key in result_by_config: return result_by_config[key]
        tag='_'.join(f'{key.lower()}{value}' for key,value in config.items())
        build_dir=directory/tag
        binary=build('tb_core_program',True,args.waves,'ooo',build_dir,config)
        sources=generated_programs(build_dir,'ooo')
        sources += sorted((ROOT/'assembly_files').glob('*.s'))
        rows=[]
        for path in sources:
            for i_delay,d_delay,jitter in DELAYS:
                name=f'{path.stem}_i{i_delay}_d{d_delay}'
                row=simulate(binary,path,name,args,'ooo',build_dir,[],i_delay,d_delay,jitter)
                row.update(config)
                rows.append(row)
                all_rows.append(row)
        result={'configuration':config,'aggregate_cycles':sum(r['cycles'] for r in rows),
                'retired':sum(r['retired'] for r in rows),'runs':{r['run']:r['cycles'] for r in rows}}
        result['ipc']=result['retired']/result['aggregate_cycles']
        results.append(result)
        result_by_config[key]=result
        write_csv(directory/'sweep.csv',all_rows)
        (directory/'progress.json').write_text(json.dumps(results,indent=2)+'\n')
        return result

    for config in configs: evaluate(config)
    selected=dict(base_config)
    choices={}
    for parameter,values in SWEEPS.items():
        candidates=[r for r in results if all(r['configuration'][key]==base_config[key] for key in base_config if key!=parameter)]
        best=min(candidates,key=lambda r:r['aggregate_cycles'])
        eligible=[r for r in candidates if r['aggregate_cycles']<=best['aggregate_cycles']*1.02]
        chosen=min(eligible,key=lambda r:r['configuration'][parameter])
        selected[parameter]=chosen['configuration'][parameter]
        regressions={name:100*(cycles/best['runs'][name]-1) for name,cycles in chosen['runs'].items() if cycles>best['runs'][name]*1.05}
        choices[parameter]={'value':selected[parameter],'best_cycles':best['aggregate_cycles'],
                            'selected_cycles':chosen['aggregate_cycles'],'regressions_over_5_percent':regressions}
    independent_selected=dict(selected)
    combined=next((r for r in results if r['configuration']==selected),None)
    if combined is None: combined=evaluate(selected)
    if not validate_combined(results,combined)['within_2_percent']:
        # Individual-axis minima can interact when combined. Measure each
        # immediate one-axis upgrade around that combination, in increasing
        # storage cost, before choosing the smallest measured joint setting.
        upgrades=[]
        for parameter,values in SWEEPS.items():
            larger=sorted(value for value in values if value>selected[parameter])
            if larger:
                candidate={**selected,parameter:larger[0]}
                if tuple(candidate[name] for name in DEFAULTS) not in result_by_config:
                    upgrades.append(candidate)
        for candidate in sorted(upgrades,key=lambda config:(storage_proxy(config),
                                                            tuple(config[name] for name in DEFAULTS))):
            evaluate(candidate)
        best_cycles=min(row['aggregate_cycles'] for row in results)
        eligible=[row for row in results if row['aggregate_cycles']<=best_cycles*1.02]
        combined=min(eligible,key=lambda row:(storage_proxy(row['configuration']),
                                               row['aggregate_cycles'],
                                               tuple(row['configuration'][name] for name in DEFAULTS)))
        selected=dict(combined['configuration'])
    validation=validate_combined(results,combined)
    report={'selected':selected,'independent_selected':independent_selected,
            'selected_storage_proxy_bits':storage_proxy(selected),
            'choices':choices,'configurations':results,
            'selection_rule':'Smallest measured storage proxy within 2% of the best measured aggregate cycles; individual-axis picks are combined and checked, then immediate one-axis upgrades are measured if needed.',
            'combined':combined,'combined_validation':validation,
            'area_note':'Capacity is a storage proxy; physical area and timing must be measured by Nangate45 synthesis/CTS.'}
    (directory/'recommendations.json').write_text(json.dumps(report,indent=2)+'\n')
    lines=['# OOO capacity sweep','',report['selection_rule'],'',report['area_note'],'',
           '| Capacity | Selected | Best aggregate cycles | Selected cycles | Regressions >5% |',
           '|---|---:|---:|---:|---:|']
    for key,choice in choices.items(): lines.append(f'| {key} | {choice["value"]} | {choice["best_cycles"]} | {choice["selected_cycles"]} | {len(choice["regressions_over_5_percent"])} |')
    lines += ['',f'Independent per-axis combination: `{independent_selected}`.',
              f'Final selected configuration: `{selected}` ({report["selected_storage_proxy_bits"]} variable storage bits).',
              f'Combined aggregate cycles: {combined["aggregate_cycles"]}; IPC: {combined["ipc"]:.6f}.',
              f'Best measured aggregate: {validation["best_measured_aggregate_cycles"]} cycles; combined change: {validation["aggregate_cycle_change_percent"]:+.4f}%; within 2%: {validation["within_2_percent"]}.','',
              'The combined selection has these individual run regressions above 5% against the best aggregate configuration:', '',
              '| Run | Selected cycles | Reference cycles | Regression |','|---|---:|---:|---:|']
    for name,row in validation['regressions_over_5_percent'].items():
        lines.append(f'| {name} | {row["cycles"]} | {row["reference_cycles"]} | {row["regression_percent"]:.2f}% |')
    lines += ['', 'Fetch-delayed runs can dominate the aggregate; the per-run regressions remain material tradeoffs.',
              'Full per-program and memory-delay results are in `sweep.csv`; comparisons with the fastest individually observed runs are also listed in `recommendations.json`.']
    (directory/'report.md').write_text('\n'.join(lines)+'\n')
    print('Capacity sweep results:',directory/'report.md')
    if not validation['within_2_percent']:
        raise RuntimeError('combined selected capacities exceed the 2% aggregate cycle limit; inspect sizing/report.md before selecting hardware')


def main():
    global BUILD_ROOT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend',choices=['inorder','ooo','both'],default='inorder')
    parser.add_argument('--suite',choices=['all','standalone','programs'],default='all')
    parser.add_argument('--program',type=Path)
    parser.add_argument('--case',help='run one generated case or assembly program by stem')
    parser.add_argument('--stop')
    parser.add_argument('--waves',action='store_true')
    parser.add_argument('--sweep',action='store_true',help='after correctness, sweep IQ, ROB and physical-register capacities')
    parser.add_argument('--build-root',type=Path,default=BUILD_ROOT,
                        help='separate generated binaries, metrics and logs (default: test/cpu/build/core)')
    parser.add_argument('--max-cycles',type=int,default=2000000)
    parser.add_argument('--l1-size',type=int,default=64*1024)
    parser.add_argument('--l2-size',type=int,default=256*1024)
    parser.add_argument('--l1-ways',type=int,default=4)
    parser.add_argument('--l2-ways',type=int,default=4)
    parser.add_argument('--l1-latency',type=int,default=1)
    parser.add_argument('--l2-latency',type=int,default=5)
    parser.add_argument('--dram-latency',type=int,default=80)
    for parameter,value in DEFAULTS.items(): parser.add_argument('--'+parameter.lower().replace('_','-'),type=int,default=value)
    args=parser.parse_args()
    BUILD_ROOT=args.build_root.resolve()
    BUILD_ROOT.mkdir(parents=True,exist_ok=True)
    run([sys.executable,HERE/'test_rv32.py'],BUILD_ROOT/'assembler_tests.log')
    print('PASS: assembler/reference known-answer tests')
    config={parameter:getattr(args,parameter.lower()) for parameter in DEFAULTS}
    rows=[]
    for backend in (('inorder','ooo') if args.backend=='both' else (args.backend,)):
        rows += run_backend(args,backend,config)
    if args.backend=='both': compare(rows)
    if args.sweep:
        if args.case or args.program or args.suite!='all': parser.error('--sweep requires a complete --suite all correctness run')
        if args.backend=='inorder': parser.error('--sweep requires --backend ooo or both')
        sweep(args,config)
    print('PASS: requested core suites')


if __name__=='__main__':
    try: main()
    except (RuntimeError,ValueError,FileNotFoundError) as error:
        print('FAIL:',error,file=sys.stderr)
        sys.exit(1)
