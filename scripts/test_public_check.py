"""Synthetic publication-guard regressions; no real credentials, audio or identity."""
from pathlib import Path
import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest

from public_check import check


class PublicCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Example')
        self.git('config', 'user.email', 'example@example.invalid')

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        for key in ('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE',
                    'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE'):
            env.pop(key, None)
        return subprocess.check_output(['git', '-C', str(self.root), *args],
                                       stderr=subprocess.STDOUT, env=env)

    def add(self, name, data=b'fictional fixture'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.git('add', '-f', '--', name)
        return path

    def commit(self):
        self.git('commit', '-q', '-m', 'Fictional export')

    def test_nested_private_artifacts_are_rejected(self):
        names = ['nested/.env', 'nested/.env.local', 'nested/.agent/output.txt',
                 'nested/.aws/config', 'captures/fixture.flac', 'captures/fixture.f32',
                 'state/fixture.sqlite', 'state/fixture.db', 'logs/events.log',
                 'logs/events.jsonl', 'captures/fixture.wav']
        for name in names:
            self.add(name)
        self.assertEqual(set(check(self.root)), {(name, 'private-artifact-type') for name in names})

    def test_source_notices_and_images_are_not_blocked_by_suffix(self):
        for name in ['README.md', 'Sources/Main.swift', 'LICENSE', 'Resources/art.png',
                     'scripts/model.json', '.github/workflows/check.yml']:
            self.add(name)
        self.assertEqual(check(self.root), [])

    def test_missing_file_and_dangling_symlink_fail_closed(self):
        missing = self.add('missing.txt')
        missing.unlink()
        (self.root / 'link').symlink_to('fictional-missing-target')
        self.git('add', '--', 'link')
        self.assertEqual(set(check(self.root)), {('missing.txt', 'missing-or-unreadable-tracked-file'),
                                               ('link', 'symlink-review')})

    def test_replaced_parent_directory_symlink_is_not_followed(self):
        path = self.add('nested/file.txt')
        path.unlink()
        path.parent.rmdir()
        with tempfile.TemporaryDirectory() as external:
            (Path(external) / 'file.txt').write_text('fictional outside content')
            path.parent.symlink_to(external, target_is_directory=True)
            self.assertEqual(check(self.root), [('nested/file.txt', 'symlink-review')])

    def test_replaced_regular_file_fifo_does_not_block_scan(self):
        path = self.add('sample.txt')
        path.unlink()
        os.mkfifo(path)
        command = ('import json,sys; from pathlib import Path; from public_check import check; '
                   'print(json.dumps(check(Path(sys.argv[1]))))')
        result = subprocess.check_output([sys.executable, '-B', '-c', command, str(self.root)],
                                         cwd=Path(__file__).resolve().parent, timeout=5)
        self.assertEqual(json.loads(result), [['sample.txt', 'non-regular-worktree-file']])

    def test_common_credential_shapes_are_detected_without_printing_values(self):
        fixtures = {
            'hf.txt': b'hf_' + b'a' * 40,
            'slack.txt': b'xoxb-' + b'1' * 30,
            'google.txt': b'AIza' + b'a' * 35,
            'aws.txt': b'ASIA' + b'A' * 16,
            'key.txt': b'-----BEGIN ' + b'ENCRYPTED PRIVATE KEY-----',
            'jwt.txt': b'eyJ' + b'a' * 12 + b'.' + b'b' * 12 + b'.' + b'c' * 12,
        }
        for name, value in fixtures.items():
            self.add(name, value)
        findings = dict(check(self.root))
        self.assertEqual(set(findings), set(fixtures))
        self.assertEqual(findings['key.txt'], 'private-key')
        self.assertEqual(findings['jwt.txt'], 'jwt-token')
        self.assertTrue(all('a' * 20 not in str(row) for row in findings.items()))

    def test_private_deny_words_cover_account_suffix_and_encodings(self):
        marker = 'fictionalperson'
        variants = [marker + '123', marker.upper(), 'prefix' + marker + 'Suffix',
                    'ＦＩＣＴＩＯＮＡＬＰＥＲＳＯＮ']
        data = [value.encode() for value in variants]
        data += [marker.encode('utf-16-le'), marker.encode('utf-16-be'), base64.b64encode(marker.encode())]
        for index, value in enumerate(data):
            self.add(f'{index}.txt', value)
        self.assertEqual(len(check(self.root, (marker,))), len(data))
        self.assertEqual(check(self.root), [])

    def test_revision_scans_commit_even_when_working_copy_was_cleaned(self):
        path = self.add('sample.txt', b'fictionalperson')
        self.commit()
        path.write_text('fictional clean replacement')
        self.assertEqual(check(self.root, ('fictionalperson',)), [])
        self.assertEqual(check(self.root, ('fictionalperson',), revision='HEAD'),
                         [('sample.txt', 'private-deny-word')])

    def test_private_identity_in_filename_is_also_rejected(self):
        self.add('fictionalperson-notes.swift')
        self.commit()
        expected = [('fictionalperson-notes.swift', 'private-deny-word')]
        self.assertEqual(check(self.root, ('fictionalperson',)), expected)
        self.assertEqual(check(self.root, ('fictionalperson',), revision='HEAD'), expected)

    def test_revision_ignores_private_uncommitted_content_and_scans_commit_metadata(self):
        path = self.add('sample.txt')
        self.git('config', 'user.name', 'fictionalperson')
        self.commit()
        path.write_bytes(b'hf_' + b'a' * 40)
        self.assertEqual(check(self.root, revision='HEAD'), [])
        self.assertEqual(check(self.root, ('fictionalperson',), revision='HEAD'),
                         [('.git/commit', 'private-deny-word')])

    def test_revision_checks_git_mode_without_following_symlink(self):
        (self.root / 'link').symlink_to('fictional-missing-target')
        self.git('add', '--', 'link')
        self.commit()
        self.assertEqual(check(self.root, revision='HEAD'), [('link', 'symlink-review')])

    def test_revision_cannot_be_a_git_option(self):
        self.add('sample.txt')
        self.commit()
        with self.assertRaises(subprocess.CalledProcessError):
            check(self.root, revision='--all')


if __name__ == '__main__':
    unittest.main()
