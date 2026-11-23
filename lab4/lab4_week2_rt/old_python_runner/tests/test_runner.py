import sys, unittest, tempfile, subprocess, time, os, signal
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_rt_tests as r

class Parsing(unittest.TestCase):
    def test_overflows_count_as_samples(self):
        s='000000 0 0 0 0\n000001 2 3 3 3\n# Total: 2 3 3 3\n# Min Latencies: 1 1 1 1\n# Avg Latencies: 1 1 1 1\n# Max Latencies: 600 1 1 1\n# Histogram Overflows: 1 0 0 0\n'
        h=r.parse_histogram(s,3)
        self.assertEqual(h['max_us'][0],600)
        self.assertEqual(h['overflows'][0],1)
    def test_truncated_rejected(self):
        with self.assertRaises(ValueError): r.parse_histogram('000001 3 3 3 3',3)
    def test_wrong_sample_count_rejected(self):
        s='000001 2 2 2 2\n# Total: 2 2 2 2\n# Min Latencies: 1 1 1 1\n# Avg Latencies: 1 1 1 1\n# Max Latencies: 1 1 1 1\n# Histogram Overflows: 0 0 0 0\n'
        with self.assertRaises(ValueError): r.parse_histogram(s,3)
    def test_perf_missing_is_not_zero(self):
        d=r.parse_perf('123;;cycles:u;1;100.00\n<not supported>;;branches:u;0;0\n1.25;seconds;time elapsed\n')
        self.assertEqual(d['cycles:u'],123)
        self.assertIsNone(d['branches:u'])
        self.assertEqual(d['time elapsed'],1.25)
    def test_cpu_iowait_is_not_busy(self):
        a={'cpu0':[10,0,10,100,10,0,0,0,0,0]}
        b={'cpu0':[20,0,20,120,20,0,0,0,0,0]}
        self.assertEqual(r.cpu_percent(a,b)['cpu0'],40)

class Processes(unittest.TestCase):
    def test_owned_tree_cleanup_keeps_other_process(self):
        other=subprocess.Popen(['sleep','30'])
        try:
            with tempfile.TemporaryDirectory() as t:
                m=r.Managed(Path(t)); p=m.start(['sh','-c','sleep 30 & wait'],'child')
                m.cleanup(); self.assertIsNotNone(p.poll())
                self.assertIsNone(other.poll())
        finally: other.terminate();other.wait()
    def test_timeout_cleans_up(self):
        with tempfile.TemporaryDirectory() as t:
            m=r.Managed(Path(t))
            with self.assertRaises(TimeoutError):m.run(['sleep','30'],'timeout',0.1)
            self.assertFalse(m.groups)
    def test_nonzero_not_success(self):
        with tempfile.TemporaryDirectory() as t:
            m=r.Managed(Path(t))
            with self.assertRaises(RuntimeError):m.run(['sh','-c','exit 7'],'fail',2)
            self.assertFalse(m.groups)

if __name__=='__main__':unittest.main()
