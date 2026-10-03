#!/usr/bin/env python3
"""Opt-in, route-only live audit. Never executes the returned plans."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Authorize live Jev routing requests and API usage')
    parser.add_argument('--output', type=Path, required=True, help='Save local results, preferably under eval/results/')
    parser.add_argument('--binary', type=Path, default=ROOT / 'app/.build/debug/varta-cli')
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=2)
    args = parser.parse_args()
    if not args.live:
        parser.error('--live is required; this audit uses your configured Jev credentials and incurs API usage')
    cases = json.loads((ROOT / 'eval/phrasing-cases.json').read_text())

    def run(case):
        result = dict(case)
        try:
            process = subprocess.run([str(args.binary.resolve()), 'route', case['command']],
                                     capture_output=True, text=True, timeout=45, cwd=ROOT)
            if process.returncode:
                raise RuntimeError('routing process failed')
            plan = json.loads(process.stdout)
            actual = {k: v.get('value') for k, v in plan.get('args', {}).items()}
            automatic = plan.get('route') in ('fastpath', 'fastpath_then_check')
            if case['intent'] is None:
                passed = plan.get('route') in ('clarify', 'computer_use')
            else:
                passed = (plan.get('intent') == case['intent'] and automatic
                          and all(actual.get(k) == v for k, v in case['args'].items()))
            result.update(passed=passed, plan=plan)
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            result.update(passed=False, error=type(error).__name__)
        return result

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run, cases))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + '\n')
    for result in results:
        if not result['passed']:
            print(f"FAIL {result['id']}: {result['command']}")
    passed = sum(result['passed'] for result in results)
    print(f'{passed}/{len(results)} phrasing cases passed. No actions executed.')
    return 0 if passed == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
