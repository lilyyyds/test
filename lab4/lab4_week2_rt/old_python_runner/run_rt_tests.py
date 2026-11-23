#!/usr/bin/env python3
"""Lab 4 RT-only acquisition. No GPIO access, installs, reboot or kernel changes."""
import argparse
import csv
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time


def save_json(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    tmp.replace(path)


def parse_histogram(text, loops):
    result = {'bins': []}
    labels = {'Total': 'total', 'Min Latencies': 'min_us',
              'Avg Latencies': 'avg_us', 'Max Latencies': 'max_us',
              'Histogram Overflows': 'overflows'}
    for line in text.splitlines():
        if re.fullmatch(r'\s*\d+(?:\s+\d+){4}\s*', line):
            result['bins'].append([int(v) for v in line.split()])
        for label, key in labels.items():
            if line.startswith('# ' + label + ':'):
                result[key] = [int(x) for x in line.split(':', 1)[1].split()]
    if not result['bins'] or any(len(result.get(k, [])) != 4 for k in labels.values()):
        raise ValueError('Missing/incomplete four-thread histogram summary')
    if len({row[0] for row in result['bins']}) != len(result['bins']):
        raise ValueError('Duplicate histogram bins; possible concatenated runs')
    for i in range(4):
        if sum(row[i+1] for row in result['bins']) != result['total'][i]:
            raise ValueError('Histogram bin sum does not match total')
        if result['total'][i] + result['overflows'][i] != loops:
            raise ValueError('Incomplete iteration count: total + overflows != requested loops')
    return result


def parse_perf(text):
    values = {}
    for line in text.splitlines():
        fields = line.strip().split(';')
        if len(fields) < 3 or line.lstrip().startswith('#'):
            continue
        value, _, event = fields[:3]
        event = event.strip()
        if not event:
            continue
        try:
            values[event] = float(value.strip())
        except ValueError:
            values[event] = None
    return values


def cpu_percent(before, after):
    out = {}
    for name, now in after.items():
        if name not in before:
            continue
        delta = [b-a for a,b in zip(before[name][:8], now[:8])]
        total = sum(delta)
        if total > 0:
            out[name] = round(100 * (total-delta[3]-delta[4])/total, 2)
    return out


def read_cpus():
    return {p[0]: [int(x) for x in p[1:]] for line in Path('/proc/stat').read_text().splitlines()
            if (p := line.split()) and re.fullmatch(r'cpu\d+', p[0])}


def memory_available_mb():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'):
            return int(line.split()[1]) / 1024
    raise RuntimeError('Cannot read MemAvailable')


def brief(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=5, env={**os.environ, 'LC_ALL': 'C'})
        return p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 'UNAVAILABLE: ' + str(e)


class CommandFailed(RuntimeError):
    pass


class Managed:
    """Only terminate process groups created by this instance."""
    def __init__(self, out):
        self.out = out
        self.groups = {}
        self.commands = []

    def start(self, cmd, label):
        logfile = self.out / (label + '.log')
        with logfile.open('w') as f:
            p = subprocess.Popen([str(x) for x in cmd], stdout=f, stderr=subprocess.STDOUT,
                                 start_new_session=True, env={**os.environ, 'LC_ALL': 'C'})
        self.groups[p.pid] = p
        self.commands.append({'label': label, 'argv': [str(x) for x in cmd],
                              'pid': p.pid, 'start': dt.datetime.now().isoformat(), 'status': 'running'})
        save_json(self.out / 'commands.json', self.commands)
        return p

    def stop(self, p):
        if p.pid not in self.groups:
            return
        # A wrapper may have exited while its children remain in its group.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
            except ProcessLookupError:
                pass
            if sig == signal.SIGTERM:
                try:
                    p.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
        p.wait()
        self.groups.pop(p.pid, None)
        for record in reversed(self.commands):
            if record['pid'] == p.pid:
                if record['status'] == 'running':
                    record['status'] = 'stopped_by_runner'
                record['returncode'] = p.returncode
                record['finished'] = dt.datetime.now().isoformat()
                break

    def cleanup(self):
        for p in list(self.groups.values()):
            self.stop(p)
        save_json(self.out / 'commands.json', self.commands)

    def run(self, cmd, label, timeout, tick=None, started=None):
        p = self.start(cmd, label)
        record = self.commands[-1]
        begin = time.monotonic()
        heartbeat = begin
        try:
            if started:
                started(p)
            while p.poll() is None:
                if time.monotonic()-begin > timeout:
                    raise TimeoutError(label + ' exceeded time limit')
                if tick:
                    tick()
                if time.monotonic()-heartbeat >= 30:
                    print(f'{label}: {time.monotonic()-begin:.0f} seconds elapsed...', flush=True)
                    heartbeat = time.monotonic()
                time.sleep(0.2)
            record['returncode'] = p.returncode
            if p.returncode:
                raise CommandFailed(f'{label} failed (exit {p.returncode}); see {label}.log')
            record['status'] = 'completed'
        except BaseException as e:
            record['status'] = 'failed_or_interrupted'
            record['error'] = str(e)
            raise
        finally:
            record['elapsed_seconds'] = time.monotonic()-begin
            self.stop(p)
            save_json(self.out / 'commands.json', self.commands)
        return (self.out / (label + '.log')).read_text(errors='replace')


class Monitor:
    def __init__(self, out):
        self.out = out
        self.rows = []
        self.phase = 'startup'
        self.previous = read_cpus()
        self.last = time.monotonic()
        self.last_health = 0
        self.baseline_flags = None
        self.workers = []
        self.historical_warning = False

    def tick(self, force=False):
        now = time.monotonic()
        if not force and now-self.last < 2:
            return
        current = read_cpus()
        cpus = cpu_percent(self.previous, current)
        self.previous, self.last = current, now
        temp = None
        tpath = Path('/sys/class/thermal/thermal_zone0/temp')
        if tpath.exists():
            temp = float(tpath.read_text()) / 1000
        mem = memory_available_mb()
        row = {'time': dt.datetime.now().isoformat(), 'phase': self.phase,
               'cpu_percent': cpus, 'temperature_c': temp, 'available_mb': round(mem, 1)}
        self.rows.append(row)
        with (self.out / 'health.jsonl').open('a') as f:
            f.write(json.dumps(row) + '\n')
        if temp is not None and temp >= 80:
            raise RuntimeError('Temperature >= 80 C; stopped owned tests. Improve cooling before retry.')
        if mem < 128:
            raise RuntimeError('Available memory < 128 MiB; stopped owned tests.')
        if shutil.disk_usage(self.out).free < 100*1024**2:
            raise RuntimeError('Free disk space < 100 MiB; stopped owned tests.')
        for p in self.workers:
            if p.poll() is not None:
                raise RuntimeError('A load worker exited; loaded measurement invalid. See worker logs.')
        if shutil.which('vcgencmd') and now-self.last_health >= 10:
            self.last_health = now
            raw = brief(['vcgencmd', 'get_throttled'])
            with (self.out / 'throttling.log').open('a') as f:
                f.write(row['time'] + ' ' + raw + '\n')
            match = re.search(r'0x[0-9a-fA-F]+', raw)
            if match:
                flags = int(match.group(),16)
                if self.baseline_flags is None:
                    self.baseline_flags = flags
                    self.historical_warning = bool(flags & 0xf0000)
                if flags & 0xf or (flags & 0xf0000 & ~self.baseline_flags):
                    raise RuntimeError('Undervoltage/throttling flag detected; stopped owned tests.')

    def pause(self, seconds):
        until = time.monotonic()+seconds
        while time.monotonic() < until:
            self.tick()
            time.sleep(0.2)

    def phase_start(self, name):
        self.phase = name
        self.previous = read_cpus()
        self.last = time.monotonic()


def write_hist(out, name, parsed):
    save_json(out/(name+'_summary.json'), {k:v for k,v in parsed.items() if k != 'bins'})
    with (out/(name+'_histogram.csv')).open('w',newline='') as f:
        writer=csv.writer(f);writer.writerow(['latency_us','thread0','thread1','thread2','thread3'])
        writer.writerows(parsed['bins'])


def plot(out, histograms):
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        return 'NOT GENERATED: matplotlib unavailable; histogram CSV files are available.'
    fig, axes = plt.subplots(len(histograms), 1, figsize=(10,4*len(histograms)), squeeze=False)
    for ax, (name, data) in zip(axes[:,0], histograms.items()):
        for i in range(4):
            ax.plot([r[0] for r in data['bins']], [r[i+1] for r in data['bins']], label=f'Thread {i}')
        ax.set_yscale('symlog', linthresh=1)
        ax.set_xlabel('Wake-up latency (microseconds)');ax.set_ylabel('Count (symlog)')
        ax.set_title(f"{name}: observed max {max(data['max_us'])} us; overflow counts {data['overflows']}")
        ax.legend();ax.grid(alpha=0.2)
    fig.tight_layout();fig.savefig(out/'latency_histograms.png', dpi=160);plt.close(fig)
    return 'latency_histograms.png (bins 0–499 us; outliers annotated, not hidden)'


def capture_schedule(out, p, label):
    # Query all threads, as the process leader may use a different policy.
    path = out/(label+'_scheduling.txt')
    with path.open('w') as f:
        f.write(brief(['ps','-T','-p',str(p.pid),'-o','pid,tid,cls,rtprio,pri,pcpu,comm'])+'\n')
        for task in sorted(Path(f'/proc/{p.pid}/task').glob('*')):
            f.write(brief(['chrt','-p',task.name])+'\n')


def report(out, state, histograms, perfrows, monitor, plot_status):
    loaded = [r for r in monitor.rows if r['phase']=='cyclic_loaded' and len(r['cpu_percent'])>=4]
    frac = sum(all(v>=90 for v in r['cpu_percent'].values()) for r in loaded)/len(loaded) if loaded else 0
    validation = 'PASS' if loaded and frac>=0.9 else 'REVIEW REQUIRED'
    lines = ['# Lab 4 RT Automatic Retest / 自动重测结果', '',
             f"Acquisition status: **{state['status']}**", '',
             f"Kernel: `{platform.release()}`", '',
             'Only the RT automatic-data portion is covered. No GPIO/scope tests or SD backups were performed.',
             '本结果不代表整个 Lab 4 已完成；普通内核对照、方波测量和备份另行完成。', '',
             '## Latency / 唤醒延迟', '',
             '| Test | Mean latency per thread (us) | Maximum per thread (us) | Overflows |',
             '|---|---|---|---|']
    for name,h in histograms.items():
        lines.append(f"| {name} | {h['avg_us']} | {h['max_us']} | {h['overflows']} |")
    lines += ['', 'Chart: '+plot_status, '', '## Load validation / 满载核验', '',
              f'{validation}: {len(loaded)} sampled intervals; {frac:.1%} had every observed core >=90% busy.',
              'This 90%/90% rule is a script quality check, not an instructor-specified threshold. '
              'Inspect health.jsonl; sampled utilization does not prove uninterrupted saturation.',
              'Four test threads are not pinned to cores. Script monitoring itself contributes some load.', '',
              '## Perf / 两种数据顺序', '', '| Variant/run | Elapsed seconds | Cycles:u | Instructions:u | Branch misses:u | Branches:u |',
              '|---|---|---|---|---|---|']
    for row in perfrows:
        def val(k): return row.get(k) if row.get(k) is not None else 'N/A'
        lines.append(f"| {row['variant']}/{row['repeat']} | {val('time elapsed')} | {val('cycles:u')} | {val('instructions:u')} | {val('branch-misses:u')} | {val('branches:u')} |")
    lines += ['', 'Elapsed time is the runner wall time around perf (includes launch/polling overhead up to about 0.2 s). For precise benchmark timing, inspect perf raw output and the program log.',
              'N/A means unavailable/not measured, never zero. See perf_probe_*.csv and perf_*.csv for raw counters and scaling.',
              'User-space hardware events (:u) are recorded for comparison with the old logs; no branch-miss rate is inferred without branches.',
              'Three paired runs help show variation; RT need not improve CPU throughput.', '',
              '## Remaining lab evidence / 仍需补齐', '',
              '- Stock-kernel loaded cyclictest and original-kernel waveform sweeps cannot be recreated on RT.',
              '- RT test_rt_v16 sweep (including 1500), matched 2500 unloaded/loaded scope readings.',
              '- blink_v7 unloaded/loaded scope readings at matched half-periods; waveform scheduling captures.',
              '- Original-kernel Python/C highest-stable-frequency plots and cross-kernel comparison.',
              '- SD backup evidence and any missing original build configuration/commit.', '',
              'Cyclic settings: -p 90 -m -t4 -i 1000 -d 0 -h 500 -q; 300000 loops per full condition. '
              'The explicit distance 0 makes all thread intervals 1000 us; the handout leaves interval defaults implicit.',
              'Quick mode is a pipeline check only; it is not the required full experiment.', '',
              '## Provenance / 可追溯记录', '',
              'See state.json, commands.json, environment.txt, source.c, source.sha256, tool help, health.jsonl, '
              'load_processes.txt, and kernel_dmesg_before/after.log. All outputs are new; older data are untouched.']
    if monitor.historical_warning:
        lines += ['', 'NOTE: historical throttling flags were already set at startup. New flags trigger an abort; inspect throttling.log.']
    if state.get('error'):
        lines += ['', '## Error', '', state['error']]
    if state.get('warnings'):
        lines += ['', '## Evidence warnings / 需要检查', ''] + ['- '+w for w in state['warnings']]
    (out/'REPORT.md').write_text('\n'.join(lines)+'\n')
    save_json(out/'load_validation.json', {'status':validation,'intervals':len(loaded),'all_cores_busy_fraction':frac})
    return validation


def preflight(source):
    if platform.system() != 'Linux' or platform.machine() not in ('aarch64','arm64'):
        raise RuntimeError('Run on the Raspberry Pi 64-bit Linux system, not on the Mac.')
    if os.geteuid()!=0:
        raise RuntimeError('Run with sudo python3 run_rt_tests.py (required for rt scheduling/perf).')
    rt = Path('/sys/kernel/realtime')
    if not (rt.exists() and rt.read_text().strip()=='1') and 'PREEMPT_RT' not in platform.version():
        raise RuntimeError('PREEMPT_RT was not detected. This runner is intentionally RT-only.')
    if len(read_cpus()) != 4:
        raise RuntimeError('This lab configuration expects four online CPU cores.')
    missing=[x for x in ('gcc','perf','cyclictest','chrt','ps','bash') if not shutil.which(x)]
    if missing:
        raise RuntimeError('Missing tools: '+', '.join(missing)+'. See README; nothing was installed.')
    if not source.is_file() or '#ifdef SORTED' not in source.read_text():
        raise RuntimeError('Expected supplied sort_v1.c with #ifdef SORTED; use the included source.')
    if memory_available_mb() < 256:
        raise RuntimeError('Need >=256 MiB available RAM before starting. Close unnecessary applications.')
    conflicts=[]
    for entry in Path('/proc').glob('[0-9]*'):
        try:
            name=(entry/'comm').read_text().strip()
            if name in ('sort_v1','sort_v1_sorted','test_rt_v16','blink_v7','cyclictest','lab4_unsorted','lab4_sorted'):
                conflicts.append(entry.name+':'+name)
        except (OSError,ProcessLookupError):
            pass
    if conflicts:
        raise RuntimeError('Existing test processes must be stopped by their owner first: '+', '.join(conflicts))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=Path(__file__).resolve().parent/'sort_v1.c')
    parser.add_argument('--out',type=Path,default=Path.cwd()/'lab4_rt_results')
    parser.add_argument('--quick',action='store_true',help='short validation only, not report-quality full test')
    parser.add_argument('--plan',action='store_true',help='show stages without privileges, loads or files')
    args=parser.parse_args()
    if args.plan:
        print('RT preflight -> compile archived source -O0 -> 3 paired perf runs -> cyclictest 10000-loop check -> unloaded histogram -> 1/4/8/12/20 persistent load ramp -> loaded histogram -> cleanup -> CSV/report/optional PNG. No GPIO, no kernel changes. Full tests use 300000 loops per condition.')
        return 0
    preflight(args.source)
    # Root-only lock directory prevents another harness and unsafe precreated lockfiles.
    lockdir=Path('/run/lab4-rt-retest')
    if lockdir.is_symlink(): raise RuntimeError('Unexpected symlink at lock directory')
    lockdir.mkdir(mode=0o700,exist_ok=True)
    if lockdir.stat().st_uid!=0 or lockdir.stat().st_mode & 0o022:
        raise RuntimeError('Unsafe lock directory permissions')
    lock=open(lockdir/'lock','w')
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: raise RuntimeError('Another retest runner is active')
    args.out.mkdir(parents=True,exist_ok=True)
    if shutil.disk_usage(args.out).free<200*1024**2: raise RuntimeError('Need >=200 MiB free space')
    out=args.out.resolve()/(dt.datetime.now().strftime('%Y%m%d_%H%M%S')+'_'+str(os.getpid()))
    out.mkdir()
    state={'status':'running','mode':'quick' if args.quick else 'full','started':dt.datetime.now().isoformat(),'kernel':platform.release()}
    save_json(out/'state.json',state)
    print('Results / 结果目录:',out,flush=True)
    manager=Managed(out);monitor=Monitor(out);histograms={};perfrows=[];plot_status='Not attempted'
    def interrupted(signum, frame): raise KeyboardInterrupt('Signal '+str(signum))
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,interrupted)
    try:
        environment=[]
        for cmd in (['uname','-a'],['cat','/etc/os-release'],['free','-h'],['df','-h'],['gcc','--version'],['perf','--version'],['lscpu']):
            environment.append('$ '+shlex.join(cmd)+'\n'+brief(cmd))
        (out/'environment.txt').write_text('\n\n'.join(environment))
        (out/'cyclictest_help.txt').write_text(brief(['cyclictest','--help']))
        (out/'kernel_dmesg_before.log').write_text(brief(['dmesg']))
        shutil.copyfile(args.source,out/'source.c')
        (out/'source.sha256').write_text(hashlib.sha256(args.source.read_bytes()).hexdigest()+'  source.c\n')
        monitor.tick(force=True)
        for variant,flags in [('unsorted',[]),('sorted',['-DSORTED'])]:
            manager.run(['gcc','-std=c99','-O0','-Wall',*flags,'-o',out/('lab4_'+variant),out/'source.c'], 'build_'+variant,120,monitor.tick)
        print('Perf: checking supported counters, then paired sort runs...',flush=True)
        events=['task-clock','context-switches','cpu-migrations','page-faults','cycles:u','instructions:u','branches:u','branch-misses:u']
        supported=[]
        for idx,event in enumerate(events):
            target=out/f'perf_probe_{idx}.csv'
            try:
                manager.run(['perf','stat','-x',';','-o',target,'-e',event,'--','sleep','0.05'],f'perf_probe_{idx}',10,monitor.tick)
                if parse_perf(target.read_text()).get(event) is not None:supported.append(event)
            except CommandFailed:
                pass  # Preserve failure log; unsupported event is not a zero count.
        save_json(out/'perf_events.json',{'requested':events,'available':supported})
        if not supported:raise RuntimeError('No perf counters available; see probe logs.')
        monitor.phase_start('perf_idle')
        for repeat in range(1,2 if args.quick else 4):
            for variant in ('unsorted','sorted'):
                label=f'perf_{variant}_{repeat}';target=out/(label+'.csv')
                manager.run(['perf','stat','-x',';','-o',target,'-e',','.join(supported),'--',out/('lab4_'+variant)],label,180,monitor.tick)
                row={'variant':variant,'repeat':repeat,**parse_perf(target.read_text())}
                row['time elapsed']=round(manager.commands[-1]['elapsed_seconds'],6)
                perfrows.append(row);save_json(out/'perf_summary.json',perfrows)
        loops=1000 if args.quick else 300000
        base=['cyclictest','-p','90','-m','-t4','-i','1000','-d','0','-q','-h','500']
        for name,count in [('cyclic_check',100 if args.quick else 10000),('cyclic_unloaded',loops)]:
            print(name, '(loops/thread:',count,')',flush=True)
            monitor.phase_start(name)
            raw=manager.run(base+['-l',str(count)],name,max(60,count*.001*2+60),monitor.tick,
                            lambda p,n=name: (time.sleep(0.1),capture_schedule(out,p,n)))
            h=parse_histogram(raw,count);write_hist(out,name,h)
            if name!='cyclic_check':histograms[name]=h
        print('Adding persistent sort load gradually: 1 -> 4 -> 8 -> 12 -> 20...',flush=True)
        monitor.phase_start('load_ramp')
        workers=[]
        for target in (1,4,8,12,20):
            while len(workers)<target:
                # Each group owns its shell and all sequential benchmark children.
                p=manager.start(['bash','-c','while true; do "$1" >/dev/null || exit $?; done','lab4-worker',out/'lab4_unsorted'],f'load_worker_{len(workers)+1}')
                workers.append(p);monitor.workers=workers
            monitor.pause(2 if args.quick else 5)
        monitor.phase_start('load_warmup');monitor.pause(3 if args.quick else 10)
        (out/'load_processes.txt').write_text(brief(['ps','-eo','pid,ppid,pgid,cls,rtprio,pcpu,comm,args']))
        child=None
        for path in Path('/proc').glob('[0-9]*/stat'):
            try:
                text=path.read_text();fields=text[text.rfind(')')+2:].split()
                if int(fields[2]) in {p.pid for p in workers} and '(lab4_unsorted)' in text:
                    child=int(path.parent.name);break
            except (OSError,ValueError,IndexError):pass
        if child:
            (out/'load_chrt.txt').write_text(brief(['chrt','-p',str(child)]))
        else:
            (out/'load_chrt.txt').write_text('NOT CAPTURED: no active sort child found at snapshot time.\n')
        if 'current scheduling policy:' not in (out/'load_chrt.txt').read_text():
            state.setdefault('warnings', []).append('Sort scheduling snapshot missing or failed; inspect load_chrt.txt and recapture chrt on an active sort PID.')
        print('cyclic_loaded (20 persistent workers)...',flush=True)
        monitor.phase_start('cyclic_loaded')
        raw=manager.run(base+['-l',str(loops)],'cyclic_loaded',max(60,loops*.001*2+60),monitor.tick,
                        lambda p:(time.sleep(0.1),capture_schedule(out,p,'cyclic_loaded')))
        h=parse_histogram(raw,loops);write_hist(out,'cyclic_loaded',h);histograms['cyclic_loaded']=h
        monitor.workers=[]
        manager.cleanup()
        state['status']='quick_check_only' if args.quick else 'acquisition_completed'
    except BaseException as e:
        state['status']='interrupted' if isinstance(e,KeyboardInterrupt) else 'failed'
        state['error']=str(e) or type(e).__name__
        print('STOP:',state['error'],file=sys.stderr,flush=True)
    finally:
        # Avoid a second Ctrl+C interrupting cleanup.
        for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,signal.SIG_IGN)
        manager.cleanup()
        (out/'kernel_dmesg_after.log').write_text(brief(['dmesg']))
        state['finished']=dt.datetime.now().isoformat()
        save_json(out/'state.json',state)
        try: plot_status=plot(out,histograms) if histograms else 'No complete histograms'
        except Exception as e:plot_status='Plot failed: '+str(e)
        validation=report(out,state,histograms,perfrows,monitor,plot_status)
        state['loaded_validation']=validation;state['plot']=plot_status
        save_json(out/'state.json',state)
        # Let the invoking non-root user copy/download their results.
        if os.environ.get('SUDO_UID') and os.environ.get('SUDO_GID'):
            uid,gid=int(os.environ['SUDO_UID']),int(os.environ['SUDO_GID'])
            for path in [out,*out.rglob('*')]:
                if not path.is_symlink():os.chown(path,uid,gid)
        print('Saved:',out/'REPORT.md',flush=True)
        lock.close()
    return 0 if state['status']=='acquisition_completed' and validation=='PASS' else 2


if __name__=='__main__':
    try:sys.exit(main())
    except (RuntimeError,OSError) as e:
        print('Cannot start:',e,file=sys.stderr);sys.exit(1)
