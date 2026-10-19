import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import package_app

class PackageSigningTests(unittest.TestCase):
    def test_vulnerable_optional_sdk_is_blocked_before_distribution_preflight(self):
        args = argparse.Namespace(mode="distribution", enable_orukeet=True,
                                  orukeet_assets=Path("fictional-stage"), resources_dir=None)
        with patch.object(package_app, "validate_assets") as validate, patch.object(package_app, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "CVE-2026-1260"):
                package_app.preflight(args)
            validate.assert_not_called()
            run.assert_not_called()

    def test_optional_sdk_preview_still_requires_pinned_input_validation(self):
        args = argparse.Namespace(mode="preview", enable_orukeet=True,
                                  orukeet_assets=Path("fictional-stage"), resources_dir=None)
        with patch.object(package_app, "validate_assets", side_effect=RuntimeError("invalid pinned input")) as validate:
            with self.assertRaisesRegex(RuntimeError, "invalid pinned input"):
                package_app.check_orukeet_options(args)
            validate.assert_called_once_with(args.orukeet_assets)

    def test_community_package_never_silently_defaults_to_apple(self):
        with self.assertRaisesRegex(RuntimeError, "default to Parakeet v3"):
            package_app.speech_configuration(argparse.Namespace())
        self.assertEqual(package_app.speech_configuration(argparse.Namespace(apple_only=True)),
                         {"TokensDefaultSpeechModel": "apple"})
        with self.assertRaisesRegex(RuntimeError, "cannot be combined"):
            package_app.speech_configuration(argparse.Namespace(apple_only=True, transcribe_worker=Path("fixture")))

    def test_transcribe_package_declares_parakeet_default_and_validates_stage(self):
        with tempfile.TemporaryDirectory() as folder:
            stage = Path(folder)
            args = argparse.Namespace(transcribe_worker=stage)
            with self.assertRaisesRegex(RuntimeError, "missing a regular transcribe-worker"):
                package_app.speech_configuration(args)
            for name in ("transcribe-worker", "LICENSE-transcribe.cpp", "THIRD-PARTY-LICENSES-transcribe.cpp.md"):
                (stage / name).write_text("fictional staged input")
            self.assertEqual(package_app.speech_configuration(args),
                             {"TokensDefaultSpeechModel": "parakeet-tdt-0.6b-v3"})
            (stage / "transcribe-worker").unlink()
            (stage / "transcribe-worker").symlink_to(stage / "LICENSE-transcribe.cpp")
            with self.assertRaisesRegex(RuntimeError, "missing a regular transcribe-worker"):
                package_app.speech_configuration(args)

    def run_signing(self, mode, identity):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            app = output / "Fixture.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/Tokens").write_bytes(b"fictional binary")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "fictional.bundle"}))
            version = app / "Contents/Frameworks/Sparkle.framework/Versions/Current"
            (version / "Updater.xpc").mkdir(parents=True)
            (version / "Autoupdate").write_bytes(b"fictional helper")
            (output / "source-manifest.json").write_text(json.dumps({"sha256": "fictional hash"}))
            calls = []
            def fake(*args, **kwargs):
                calls.append(args)
                if args[:3] == ("git", "rev-parse", "HEAD"): return "fictional commit"
                if args[:3] == ("git", "status", "--porcelain"): return ""
                if args[:3] == ("xcrun", "notarytool", "submit"): return json.dumps({"status": "Accepted"})
                return ""
            args = argparse.Namespace(mode=mode, identity=identity, binary=None, notary_profile="fictional profile")
            with patch.object(package_app, "run", fake), patch.object(package_app.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="fictional signature")):
                package_app.sign_and_verify(args, app, output)
            return calls

    def test_ad_hoc_preview_signs_every_layer_without_hardened_library_validation(self):
        calls = self.run_signing("preview", None)
        signed = [call for call in calls if call[:2] == ("codesign", "--force")]
        self.assertEqual(len(signed), 4)
        for call in signed:
            self.assertNotIn("runtime", call)
            self.assertEqual(call[call.index("--sign") + 1], "-")
            self.assertIn("--timestamp=none", call)
        self.assertFalse(any("notarytool" in call or call[0] == "spctl" for call in calls))

    def test_real_signed_modes_keep_runtime_and_public_timestamp_notary_gatekeeper(self):
        for mode in ("preview", "dev", "distribution"):
            with self.subTest(mode=mode):
                calls = self.run_signing(mode, "fictional signed identity")
                signed = [call for call in calls if call[:2] == ("codesign", "--force")]
                self.assertEqual(len(signed), 4)
                for call in signed:
                    self.assertIn("runtime", call)
                    self.assertIn("--timestamp" if mode == "distribution" else "--timestamp=none", call)
                self.assertEqual(any("notarytool" in call for call in calls), mode == "distribution")
                self.assertEqual(any(call[0] == "spctl" for call in calls), mode == "distribution")

    def test_transcribe_bundle_preserves_and_hashes_upstream_notices(self):
        self.check_transcribe_notices(missing=None)

    def test_transcribe_bundle_refuses_missing_engine_or_dependency_notices(self):
        for missing in ("LICENSE-transcribe.cpp", "THIRD-PARTY-LICENSES-transcribe.cpp.md"):
            with self.subTest(missing=missing):
                self.check_transcribe_notices(missing=missing)

    def test_transcribe_stage_change_is_rejected_before_signing(self):
        self.check_transcribe_notices(missing=None, tampered=True)

    def check_transcribe_notices(self, missing, tampered=False):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            app = output / "Fixture.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/Tokens").write_bytes(b"fictional binary")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "fictional.bundle"}))
            (output / "source-manifest.json").write_text(json.dumps({"sha256": "fictional hash"}))
            stage = output / "worker-stage"
            stage.mkdir()
            texts = {"transcribe-worker": b"fictional worker",
                     "LICENSE-transcribe.cpp": b"fictional upstream engine license\n",
                     "THIRD-PARTY-LICENSES-transcribe.cpp.md": b"fictional upstream component notices\n"}
            for name, content in texts.items():
                if name != missing:
                    (stage / name).write_bytes(content)
            (output / "source-manifest.json").write_text(json.dumps({
                "sha256": "fictional hash", "files": [
                    {"path": "transcribe-assets/" + name, "sha256": hashlib.sha256(data).hexdigest()}
                    for name, data in texts.items()]}))
            if tampered:
                (stage / "transcribe-worker").write_bytes(b"changed after manifest")
            calls = []
            def fake(*args, **kwargs):
                calls.append(args)
                if args[:2] == ("lipo", "-archs"): return "arm64"
                if args[:2] == ("otool", "-L"): return "fixture:\n /usr/lib/libSystem.B.dylib (compatibility version 1.0.0)"
                if args[:3] == ("git", "rev-parse", "HEAD"): return "fictional commit"
                return ""
            args = argparse.Namespace(mode="preview", identity=None, binary=None, transcribe_worker=stage)
            with patch.object(package_app, "run", fake), patch.object(package_app.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="fictional signature")):
                if missing:
                    with self.assertRaisesRegex(RuntimeError, "missing " + missing):
                        package_app.sign_and_verify(args, app, output)
                    self.assertFalse(any(call[0] == "codesign" for call in calls))
                    return
                if tampered:
                    with self.assertRaisesRegex(RuntimeError, "changed after source manifest"):
                        package_app.sign_and_verify(args, app, output)
                    self.assertFalse(any(call[0] == "codesign" for call in calls))
                    return
                receipt = package_app.sign_and_verify(args, app, output)
            target = app / "Contents/Resources/Transcribe"
            for name, content in texts.items():
                self.assertEqual((target / name).read_bytes(), content)
            self.assertEqual(receipt["transcribe_worker"]["third_party_notices_sha256"],
                             hashlib.sha256(texts["THIRD-PARTY-LICENSES-transcribe.cpp.md"]).hexdigest())

if __name__ == "__main__": unittest.main()
