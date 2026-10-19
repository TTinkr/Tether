#!/usr/bin/env python3
"""Scan tracked working files, or an immutable Git commit with --revision.

Private deny words stay in PUBLIC_EXPORT_DENY_WORDS, never in public source.
This is a heuristic guard, not a security certification or image/OCR review.
"""
import argparse
import base64
import binascii
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
RULES = {
    'private-key': rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED |DSA )?PRIVATE KEY-----',
    'provider-token': (
        rb'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|'
        rb'(?:AKIA|ASIA)[0-9A-Z]{16}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}|'
        rb'hf_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[A-Za-z0-9_-]{35}'
    ),
    'jwt-token': rb'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',
    'home-path': rb'/(?:Users|home)/[^/\s"<>]+|[A-Z]:\\Users\\[^\\\s"<>]+',
}
PRIVATE_SUFFIXES = {
    '.p12', '.p8', '.key', '.pem', '.mobileprovision', '.provisionprofile',
    '.caf', '.wav', '.mp3', '.m4a', '.flac', '.aif', '.aiff', '.ogg', '.opus',
    '.pcm', '.f32', '.mov', '.mp4', '.webm', '.mkv', '.avi',
    '.gz', '.zip', '.tar', '.tgz', '.bz2', '.xz', '.7z',
    '.sqlite', '.sqlite3', '.db', '.log', '.jsonl',
}
BASE64_RUN = re.compile(rb'(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{12,}={0,2}(?![A-Za-z0-9+/])')


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def resolve_commit(root, revision):
    # Resolve before passing a ref to other commands. User input cannot become an option.
    commit = git(root, 'rev-parse', '--verify', '--end-of-options', revision + '^{commit}').decode().strip()
    if not re.fullmatch(r'[0-9a-f]{40,64}', commit):
        raise ValueError('Revision did not resolve to one commit')
    return commit


def private_artifact(name):
    path = PurePosixPath(name)
    return (any(part in {'.agent', '.ssh', '.aws'} or part == '.env' or part.startswith('.env.')
                for part in path.parts)
            or name.startswith('scripts/speech_bench/results/')
            or path.suffix.lower() in PRIVATE_SUFFIXES)


def contains_deny_word(data, deny_words):
    if not deny_words:
        return False
    # Deliberately substring-based: account-name suffixes and CamelCase are still identity.
    words = [unicodedata.normalize('NFKC', word).casefold() for word in deny_words if word]

    def matches(value):
        encodings = ['utf-8'] + (['utf-16-le', 'utf-16-be'] if b'\0' in value else [])
        for encoding in encodings:
            text = unicodedata.normalize('NFKC', value.decode(encoding, errors='ignore')).casefold()
            if any(word in text for word in words):
                return True
        return False

    if matches(data):
        return True
    # One bounded decoding layer catches ordinary encoded fixtures, not arbitrary steganography.
    for match in BASE64_RUN.finditer(data):
        encoded = match.group()
        if len(encoded) > 65536:
            continue
        try:
            decoded = base64.b64decode(encoded + b'=' * (-len(encoded) % 4), validate=True)
        except (binascii.Error, ValueError):
            continue
        if matches(decoded):
            return True
    return False


def content_findings(name, data, deny_words):
    filename = os.fsencode(name)
    found = [(name, label) for label, pattern in RULES.items()
             if re.search(pattern, data) or re.search(pattern, filename)]
    if contains_deny_word(data, deny_words) or contains_deny_word(filename, deny_words):
        found.append((name, 'private-deny-word'))
    return found


class NonRegularFileError(OSError):
    pass


def read_working_file(root, name):
    """Anchor each component to directory descriptors; never follow links or read a pipe."""
    parts = PurePosixPath(name).parts
    if not parts or PurePosixPath(name).is_absolute() or '..' in parts:
        raise OSError('Invalid tracked path')
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
    directory = os.open(root, directory_flags)
    try:
        for part in parts[:-1]:
            child = os.open(part, directory_flags, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise NonRegularFileError('Tracked working file is not regular')
            with os.fdopen(descriptor, 'rb', closefd=False) as stream:
                return stream.read()
        finally:
            os.close(descriptor)
    finally:
        os.close(directory)


def check(root, deny_words=(), revision=None):
    root = Path(root)
    findings = []
    commit = resolve_commit(root, revision) if revision else None
    if commit:
        records = git(root, 'ls-tree', '-r', '-z', '--full-tree', commit).split(b'\0')
    else:
        records = git(root, 'ls-files', '--stage', '-z').split(b'\0')
    for record in filter(None, records):
        metadata, raw_name = record.split(b'\t', 1)
        name = os.fsdecode(raw_name)
        fields = metadata.decode().split()
        mode = fields[0]
        if mode not in ('100644', '100755'):
            findings.extend(content_findings(name, b'', deny_words))
            findings.append((name, 'symlink-review' if mode == '120000' else 'unsupported-git-mode'))
            continue
        if private_artifact(name):
            findings.append((name, 'private-artifact-type'))
        if commit:
            data = git(root, 'cat-file', 'blob', fields[2])
        else:
            if fields[2] != '0':
                findings.append((name, 'unmerged-file'))
                continue
            # Check ancestors too: a replaced directory must not escape the audited root.
            if any((root / Path(*Path(name).parts[:n])).is_symlink()
                   for n in range(1, len(Path(name).parts) + 1)):
                findings.append((name, 'symlink-review'))
                continue
            try:
                data = read_working_file(root, name)
            except NonRegularFileError:
                findings.append((name, 'non-regular-worktree-file'))
                continue
            except OSError:
                findings.append((name, 'missing-or-unreadable-tracked-file'))
                continue
        findings.extend(content_findings(name, data, deny_words))
    if commit:
        findings.extend(content_findings('.git/commit', git(root, 'cat-file', 'commit', commit), deny_words))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', help='Scan files and metadata from this commit, independent of working edits (use HEAD before publication)')
    parser.add_argument('--snapshot-history', action='store_true', help='Require the selected commit (or HEAD) to have no private ancestors')
    args = parser.parse_args()
    denied = [x.strip() for x in os.environ.get('PUBLIC_EXPORT_DENY_WORDS', '').split(',') if x.strip()]
    findings = check(ROOT, denied, revision=args.revision)
    if args.snapshot_history:
        commit = resolve_commit(ROOT, args.revision or 'HEAD')
        if int(git(ROOT, 'rev-list', '--count', commit)) != 1:
            findings.append(('.git', 'snapshot-has-history'))
    for file, kind in findings:
        print(f'{file}: {kind}')
    scope = f'commit {args.revision}' if args.revision else 'tracked working files (not staged/committed bytes)'
    print(f'Public export check [{scope}]: {len(findings)} finding(s). Heuristic scan; not a security certification.')
    return bool(findings)


if __name__ == '__main__':
    sys.exit(main())
