#!/usr/bin/env python3
"""Export timing-only summaries from local Varta logs; never export dictated text."""
import argparse
import json
import math
from collections import Counter
from pathlib import Path
import re


def distribution(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return {'count': 0}
    return {'count': len(values), 'median_ms': round(values[math.ceil(len(values)*.5)-1], 1),
            'p95_ms': round(values[math.ceil(len(values)*.95)-1], 1), 'min_ms': round(values[0], 1), 'max_ms': round(values[-1], 1)}


def summarize(samples):
    return {'attempts': len(samples), 'outcomes': dict(Counter(s['outcome'] for s in samples)),
            'stages': {key: distribution([s.get(key) for s in samples]) for key in
                       ['transcriptMs', 'transcriptToPlanMs', 'planToStatusMs', 'releaseToStatusMs']},
            'successfulStatusMs': distribution([s['releaseToStatusMs'] for s in samples if s['outcome'] == 'success']),
            'successfulUnderOneSecond': sum(s['outcome'] == 'success' and s['releaseToStatusMs'] < 1000 for s in samples)}


def parse_log(text):
    samples, pending, incomplete = [], None, 0
    day, previous = 0, 0
    for line in text.splitlines():
        stamp = re.match(r'^(\d\d):(\d\d):(\d\d\.\d+) (.*)$', line)
        if not stamp:
            continue
        hour, minute, second, message = stamp.groups()
        t = int(hour)*3600 + int(minute)*60 + float(second)
        if previous - t > 12*3600:
            day += 86400
        previous = t
        t = (t+day)*1000
        if message.startswith('timing '):
            raw = json.loads(message[7:])
            allowed = ['intent', 'speechSource', 'outcome', 'transcriptMs', 'transcriptToPlanMs', 'planToStatusMs', 'releaseToStatusMs']
            row = {key: raw.get(key) for key in allowed}
            row['measurement'] = 'monotonic_voice_status'
            samples.append(row); pending = None
            continue
        match = re.match(r'transcript \((.*?), ([\d.]+) ms after release, held [\d.]+ s\):', message)
        if match:
            if pending is not None:
                incomplete += 1
            pending = {'speechSource': match[1], 'transcriptMs': float(match[2]), '_transcript': t,
                       'measurement': 'legacy_stop_to_status_estimate', 'intent': None}
        elif message == 'launched':
            if pending is not None:
                incomplete += 1; pending = None
        elif pending is not None and message.startswith('plan '):
            intent = re.search(r'"intent":"([a-z_]+)"', message)
            if intent:
                pending['intent'] = intent[1]
            pending['_plan'] = t
        elif pending is not None and (message.startswith('notch ') or message.startswith('clarify ')):
            row = pending; pending = None
            transcribed = row.pop('_transcript'); planned = row.pop('_plan', None)
            row['outcome'] = 'clarification' if message.startswith('clarify ') else 'success' if '●' in message else 'failure'
            row['releaseToStatusMs'] = t - transcribed + row['transcriptMs']
            row['transcriptToPlanMs'] = planned - transcribed if planned is not None else None
            row['planToStatusMs'] = t - planned if planned is not None else None
            samples.append(row)
    return samples, incomplete + (pending is not None)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--log', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    samples, incomplete = parse_log(args.log.read_text())
    report = {'benchmark': 'observational-voice-log-status-v1', 'incompleteAttempts': incomplete,
              'all': summarize(samples), 'byIntent': {intent: summarize([s for s in samples if (s['intent'] or 'unclassified') == intent])
              for intent in sorted({s['intent'] or 'unclassified' for s in samples})}, 'samples': samples,
              'notes': ['No transcripts, titles, paths, calendar data or provider bodies exported.',
                        'Legacy logs span builds and uncontrolled human voice commands; successful status is not independently judged correctness.',
                        'Legacy start is transcription-stop task entry, estimated from a rounded duration plus wall-clock log times; not exact physical key release.',
                        'Modern timing records use monotonic time from stopListening entry to pipeline status, before UI presentation.',
                        'Incomplete attempts are counted separately; completed failures and clarifications remain in all-attempt distributions.',
                        'Nearest-rank percentiles. No inferred speech-recognition accuracy or visible-action timestamps.']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'incomplete': incomplete, 'all': report['all'], 'byIntent': report['byIntent']}, indent=2))


if __name__ == '__main__':
    main()
