#!/usr/bin/env python3
"""Source-extracted wiring with a stub surrounding model is NOT installed UI/microphone proof.

Compiles three unchanged production methods and the Copy latest getter with the actual recovery store and
fictional Foundation-only fixtures. Never initializes TalkModel or accesses
permissions, preferences, audio, real history, or a pasteboard.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
METHODS = {
    'clearPromptHistory': 'Sources/Tokens/Talk/TalkModel+History.swift',
    'restoreTranscriptRecovery': 'Sources/Tokens/Talk/TalkModel+Startup.swift',
    'offersAtLaunch': 'Sources/Tokens/Talk/TalkModel+Startup.swift',
    'refreshEarlierRecovery': 'Sources/Tokens/Talk/TalkModel+Recovery.swift',
    'checkpointTranscript': 'Sources/Tokens/Talk/TalkModel+Recovery.swift',
    'prepareRecoveredWordsForNewTalk': 'Sources/Tokens/Talk/TalkModel+Capture.swift',
    'latestTranscript': 'Sources/Tokens/Talk/TalkModel+Copy.swift',
    'finishClearingRecoveryJournal': 'Sources/Tokens/Talk/TalkModel+History.swift',
    'sessionsSparedByHistoryClear': 'Sources/Tokens/Talk/TalkModel+History.swift',
}
STORE = 'Sources/Tokens/Store/TranscriptRecovery.swift'


def extract_method(source, name):
    """Retain the exact method bytes, including comments and string literals."""
    pattern = r'^    var latestTranscript: String \{' if name == 'latestTranscript' else r'^    (?:private )?(?:static )?func ' + re.escape(name) + r'\([^\n]*\)(?: -> [^{\n]+)? \{'
    matches = list(re.finditer(pattern, source, re.M))
    if len(matches) != 1:
        raise RuntimeError(f'Expected exactly one production {name}()')
    start = matches[0].start()
    index = source.index('{', matches[0].start())
    depth = 0
    state = 'code'
    block_depth = 0
    while index < len(source):
        char, pair = source[index], source[index:index + 2]
        if state == 'line':
            if char == '\n': state = 'code'
        elif state == 'block':
            if pair == '/*': block_depth += 1; index += 1
            elif pair == '*/':
                block_depth -= 1; index += 1
                if not block_depth: state = 'code'
        elif state == 'string':
            if char == '\\': index += 1
            elif char == '"': state = 'code'
        elif pair == '//': state = 'line'; index += 1
        elif pair == '/*': state = 'block'; block_depth = 1; index += 1
        elif char == '"': state = 'string'
        elif char == '{': depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0: return source[start:index + 1]
        index += 1
    raise RuntimeError(f'Unbalanced production method {name}')


def run(output):
    output.mkdir(parents=True, exist_ok=False)
    paths = list(METHODS.values()) + [STORE, 'scripts/test_recovery_wiring_fixture.swift',
                                         'scripts/test_recovery_wiring.py']
    inputs = {path: (ROOT / path).read_bytes() for path in paths}
    methods = {name: extract_method(inputs[path].decode(), name) for name, path in METHODS.items()}
    fixture = inputs['scripts/test_recovery_wiring_fixture.swift'].decode()
    if fixture.count('/* PRODUCTION_METHODS */') != 1:
        raise RuntimeError('Missing unique fixture extraction slot')
    generated = fixture.replace('/* PRODUCTION_METHODS */', '\n\n'.join(methods.values()))
    # Keep a standalone, reviewable copy of the unchanged store and extracted methods.
    (output / 'RecoveryWiringHarness.swift').write_text(generated)
    (output / 'TranscriptRecovery.swift').write_bytes(inputs[STORE])
    source_pin = {path: hashlib.sha256(data).hexdigest() for path, data in inputs.items()}
    callsites = {
        'startup_calls_restore': 'if !isSyntheticRun { restoreTranscriptRecovery() }' in inputs[METHODS['restoreTranscriptRecovery']].decode(),
        'capture_calls_prepare': len(re.findall(r'^\s*prepareRecoveredWordsForNewTalk\(\)', inputs[METHODS['prepareRecoveredWordsForNewTalk']].decode(), re.M)) == 1,
    }
    with tempfile.TemporaryDirectory(prefix='tokens-fictional-recovery-wiring-') as temporary:
        executable = Path(temporary) / 'wiring-check'
        command = ['/usr/bin/xcrun', 'swiftc', '-parse-as-library',
                   str(output / 'TranscriptRecovery.swift'), str(output / 'RecoveryWiringHarness.swift'),
                   '-o', str(executable)]
        compiled = subprocess.run(command, text=True, capture_output=True, timeout=90)
        (output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError(f'Focused Swift harness compilation failed; see {output / "compile.log"}')
        execution = subprocess.run([str(executable)], text=True, capture_output=True, timeout=30)
        (output / 'execution.log').write_text(execution.stdout + execution.stderr)
        cases = json.loads(execution.stdout)
    stable = all((ROOT / path).read_bytes() == data for path, data in inputs.items())
    result = {'boundary': __doc__.split('\n')[0], 'source_sha256': source_pin,
              'method_sha256': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in methods.items()},
              'callsite_checks': callsites, 'source_unchanged_during_run': stable,
              'cases': cases, 'passed': execution.returncode == 0 and stable and all(callsites.values())
              and all(case['passed'] for case in cases),
              'proof_limits': ['PromptHistoryStore is a controlled fixture stub; TranscriptRecoveryStore is production source.',
                               'clearHeldWords is a counted callback; no real UI, microphone, permissions, preferences or transcript.']}
    (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New artifact directory; never overwritten')
    raise SystemExit(run(parser.parse_args().output.resolve()))
