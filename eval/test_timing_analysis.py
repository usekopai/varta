"""Offline checks for log association, privacy, and timing summaries."""
import json
from pathlib import Path
import runpy
import unittest

MODULE = runpy.run_path(str(Path(__file__).with_name('analyze-timings.py')))
parse = MODULE['parse_log']


class TimingAnalysisTests(unittest.TestCase):
    def test_midnight_and_redaction(self):
        rows, incomplete = parse('23:59:59.000 transcript (cached, 100 ms after release, held 1.0 s): "PRIVATE"\n'
                                 '23:59:59.500 plan      {"intent":"open_app","args":{"private":"data"}}\n'
                                 '00:00:00.000 notch     ● PRIVATE\n')
        self.assertEqual(rows[0]['releaseToStatusMs'], 1100)
        self.assertEqual(incomplete, 0)
        self.assertNotIn('PRIVATE', json.dumps(rows))
        self.assertNotIn('args', json.dumps(rows))

    def test_modern_record_replaces_legacy_pair(self):
        record = dict(intent='open_app', outcome='success', releaseToStatusMs=250, transcript='PRIVATE')
        rows, incomplete = parse('12:00:00.000 transcript (cached, 0 ms after release, held 1.0 s): "PRIVATE"\n'
                                 '12:00:00.250 timing '+json.dumps(record)+'\n12:00:00.251 notch     ● PRIVATE\n')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['measurement'], 'monotonic_voice_status')
        self.assertNotIn('PRIVATE', json.dumps(rows))
        self.assertEqual(incomplete, 0)

    def test_interruption_and_failure_not_dropped(self):
        prefix = 'transcript (cached, 10 ms after release, held 1.0 s): "PRIVATE"'
        rows, incomplete = parse(f'12:00:00.000 {prefix}\n12:00:01.000 {prefix}\n12:00:02.000 notch     ○ failed\n')
        self.assertEqual(incomplete, 1)
        self.assertEqual(rows[0]['outcome'], 'failure')
        summary = MODULE['summarize'](rows)
        self.assertEqual(summary['attempts'], 1)
        self.assertEqual(summary['successfulStatusMs']['count'], 0)

    def test_nearest_rank(self):
        d = MODULE['distribution']([4, None, 1, 3, 2])
        self.assertEqual(d['median_ms'], 2)
        self.assertEqual(d['p95_ms'], 4)


if __name__ == '__main__':
    unittest.main()
