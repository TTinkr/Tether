#!/usr/bin/env python3
"""Actual extracted recovery/delivery wiring with fictional stubs; NOT UI/microphone proof."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TALK = 'Sources/Tokens/Talk/'
PATHS = [TALK + 'TalkModel+History.swift', TALK + 'TalkModel+Delivery.swift',
         TALK + 'TalkModel+Recovery.swift', TALK + 'TalkModel+Copy.swift',
         'Sources/Tokens/Store/TranscriptRecovery.swift', 'Sources/Tokens/Transcript/TokensPrompt.swift']


def extract_block(source, pattern):
    matches = list(re.finditer(pattern, source, re.M))
    if len(matches) != 1:
        raise RuntimeError(f'Expected one production block: {pattern}')
    start = matches[0].start()
    index = source.index('{', matches[0].end() - 1)
    depth, state, comments = 0, 'code', 0
    while index < len(source):
        char, pair = source[index], source[index:index + 2]
        if state == 'line':
            if char == '\n': state = 'code'
        elif state == 'block':
            if pair == '/*': comments += 1; index += 1
            elif pair == '*/':
                comments -= 1; index += 1
                if not comments: state = 'code'
        elif state == 'string':
            if char == '\\': index += 1
            elif char == '"': state = 'code'
        elif pair == '//': state = 'line'; index += 1
        elif pair == '/*': state = 'block'; comments = 1; index += 1
        elif char == '"': state = 'string'
        elif char == '{': depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0: return source[start:index + 1]
        index += 1
    raise RuntimeError('Unbalanced source block')


def run(source_root, output):
    output.mkdir(parents=True, exist_ok=False)
    inputs = {path: (source_root / path).read_bytes() for path in PATHS}
    fragments = {}
    for label, path in [('history', PATHS[0]), ('delivery', PATHS[1])]:
        extension = extract_block(inputs[path].decode(), r'^extension TalkModel \{')
        fragments[label] = extension[extension.index('{') + 1:-1]
    recovery = inputs[PATHS[2]].decode()
    for name in ['checkpointTranscript', 'resolveTranscriptRecovery']:
        # Attribute lines and a return type are part of the method (build 81: @discardableResult -> Bool).
        fragments[name] = extract_block(recovery, r'^    (?:@\w+\n    )*func ' + name + r'\([^\n]*\)(?: -> [^\n{]+)? \{')
    fragments['latestTranscript'] = extract_block(inputs[PATHS[3]].decode(), r'^    var latestTranscript: String \{')
    # Build 81 moved the Return decision out of deliver; extract that gate rather than fake it.
    fragments['TokensAutoSendDelivery'] = extract_block(inputs[PATHS[5]].decode(), r'^enum TokensAutoSendDelivery \{')
    fixture_path = ROOT / 'scripts/test_recovery_retry_delivery_fixture.swift'
    fixture = fixture_path.read_text()
    assert fixture.count('/* EXTRACTED_PRODUCTION */') == 1
    generated = fixture.replace('/* EXTRACTED_PRODUCTION */', '\n\n'.join(fragments.values()))
    (output / 'RetryDeliveryHarness.swift').write_text(generated)
    (output / 'TranscriptRecovery.swift').write_bytes(inputs[PATHS[4]])
    with tempfile.TemporaryDirectory(prefix='tokens-fictional-retry-delivery-') as temporary:
        executable = Path(temporary) / 'checks'
        compiled = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-parse-as-library',
            str(output / 'TranscriptRecovery.swift'), str(output / 'RetryDeliveryHarness.swift'),
            '-o', str(executable)], capture_output=True, text=True, timeout=90)
        (output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError(f'Focused compilation failed: {output / "compile.log"}')
        executed = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
        (output / 'execution.log').write_text(executed.stdout + executed.stderr)
        marker = 'RECOVERY_RESULT_JSON='
        records = [line[len(marker):] for line in executed.stdout.splitlines() if line.startswith(marker)]
        if len(records) != 1:
            raise RuntimeError('Harness did not emit one result record')
        cases = json.loads(records[0])
    stable = all((source_root / path).read_bytes() == data for path, data in inputs.items())
    result = {'boundary': __doc__, 'source_root': str(source_root),
        'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source_root, text=True).strip(),
        'source_sha256': {path: hashlib.sha256(data).hexdigest() for path, data in inputs.items()},
        'extracted_sha256': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in fragments.items()},
        'fixture_sha256': hashlib.sha256(fixture.encode()).hexdigest(), 'source_unchanged': stable,
        'cases': cases, 'passed': stable and executed.returncode == 0 and all(case['passed'] for case in cases),
        'limits': ['Actual full history/delivery extension bodies, checkpoint/resolve/copy getter and auto-send Return gate run unchanged.',
                   'Actual recovery store uses only fictional temporary files.',
                   'History persistence, target delivery, rendering, return input and presentation are minimal controlled stubs.',
                   'No real model initialization, UI, microphone, permissions, preferences, clipboard, app build or installation.']}
    (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.source_root.resolve(), args.output.resolve()))
