#!/usr/bin/env python3
"""Public configuration fixtures; no production keys, Keychain or network operations."""

import base64
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import package_app
from update_config import update_configuration


FEED = "https://keeptinkr.ing/tokens/appcast.xml"
# Arbitrary public-shaped fixture only. Never use it in a distributed app.
PUBLIC_FIXTURE = base64.b64encode(bytes(range(32))).decode("ascii")


class UpdateConfigurationTests(unittest.TestCase):
    def test_optional_absent_configuration(self):
        self.assertEqual(update_configuration(None, None), {})

    def test_distribution_requires_complete_configuration(self):
        for feed, key in ((None, None), (FEED, None), (None, PUBLIC_FIXTURE)):
            with self.subTest(feed=feed):
                with self.assertRaises(ValueError):
                    update_configuration(feed, key, required=True)

    def test_valid_https_public_configuration(self):
        self.assertEqual(update_configuration(FEED, PUBLIC_FIXTURE, required=True),
                         {"SUFeedURL": FEED, "SUPublicEDKey": PUBLIC_FIXTURE})

    def test_rejects_unsafe_or_malformed_feeds(self):
        for feed in ("http://keeptinkr.ing/feed", "https:///feed", "https://user@keeptinkr.ing/feed",
                     "https://user:password@keeptinkr.ing/feed", FEED + "#fragment", FEED + "?query=1",
                     "https://localhost/feed", "https://127.0.0.1/feed", "https://192.168.1.2/feed",
                     "https://host.local/feed", "https://[::1]/feed", "https://keeptinkr.ing:bad/feed",
                     "https://keeptinkr.ing:8443/feed", "https://keeptinkr.ing", " " + FEED,
                     FEED + "\n", "https://keep tinkr.ing/feed", "https://keeptinkr.ing\\other/feed"):
            with self.subTest(feed=feed):
                with self.assertRaises(ValueError):
                    update_configuration(feed, PUBLIC_FIXTURE)

    def test_rejects_invalid_or_placeholder_public_keys(self):
        for key in ("", "not base64", PUBLIC_FIXTURE + "\n", PUBLIC_FIXTURE + "=",
                    base64.b64encode(bytes(31)).decode(), base64.b64encode(bytes(33)).decode(),
                    base64.b64encode(bytes(32)).decode(), 123):
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    update_configuration(FEED, key)

    def test_invalid_configuration_fails_before_build_or_keychain(self):
        args = package_app.parser().parse_args(["--apple-only", "--mode", "distribution"])
        with patch.object(package_app, "run") as run:
            with self.assertRaises(ValueError):
                package_app.preflight(args)
        run.assert_not_called()

    def test_distribution_requires_reviewed_assets_before_credentials(self):
        args = package_app.parser().parse_args(["--apple-only", "--mode", "distribution", "--feed-url", FEED,
                                               "--ed-public-key", PUBLIC_FIXTURE])
        with patch.object(package_app, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "reviewed"):
                package_app.preflight(args)
        run.assert_not_called()

    def test_bundle_fields_and_asset_manifest_match_in_isolated_fixture(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
                (root / notice).write_text("fixture notice")
            assets = root / "reviewed-public-assets"
            (assets / "WaveIdentity").mkdir(parents=True)
            for name in ("TTT.icns", "WaveIdentity/mark.png", "WaveIdentity/PROVENANCE.md"):
                (assets / name).write_bytes(b"fictional asset")
            binary = root / "fictional-binary"
            binary.write_bytes(b"fictional executable /tmp/example-user/build")
            binary.chmod(0o755)
            args = package_app.parser().parse_args(["--apple-only", "--mode", "distribution", "--binary", str(binary),
                "--resources-dir", str(assets), "--feed-url", FEED, "--ed-public-key", PUBLIC_FIXTURE,
                "--version", "0.3.0", "--build-number", "10"])

            def commands(*argv, **kwargs):
                if argv[0] == "otool":
                    return "fixture:\n\t/System/Library/Frameworks/AppKit.framework/AppKit (version fixture)"
                if argv[0] == "strip":
                    Path(argv[-1]).write_bytes(b"fictional stripped executable")
                    return ""
                self.fail("Unexpected external command: " + repr(argv))

            with patch.object(package_app, "ROOT", root), patch.object(package_app, "run", side_effect=commands):
                manifest = package_app.source_manifest(assets)
                app, output = package_app.assemble(args, "a" * 40, manifest)
            metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(metadata["SUFeedURL"], FEED)
            self.assertEqual(metadata["SUPublicEDKey"], PUBLIC_FIXTURE)
            self.assertFalse(metadata["SUEnableAutomaticChecks"])
            self.assertFalse(metadata["SUSendProfileInfo"])
            self.assertEqual(metadata["CFBundleIdentifier"], "com.tinkr.tokens.community.macos")
            self.assertEqual(metadata["CFBundleVersion"], "10")
            self.assertNotIn("TTTDevChannel", metadata)
            asset_rows = [r for r in manifest["files"] if r["path"].startswith("bundle-assets/")]
            self.assertEqual(len(asset_rows), 2)
            for row in asset_rows:
                self.assertTrue((app / "Contents/Resources" / row["path"].removeprefix("bundle-assets/")).is_file())
            self.assertFalse((app / "Contents/Resources/WaveIdentity/PROVENANCE.md").exists())
            self.assertFalse((output / "Tokens.unstripped").exists())
            self.assertEqual((app / "Contents/Resources/LICENSE").read_text(), "fixture notice")
            self.assertNotIn(b"/Users/", (app / "Contents/MacOS/Tokens").read_bytes())

    def test_distribution_rejects_known_dev_assets_before_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            assets = root / "Resources/Dev"
            (assets / "WaveIdentity").mkdir(parents=True)
            (assets / "TTT.icns").touch()
            args = package_app.parser().parse_args(["--apple-only", "--mode", "distribution", "--feed-url", FEED,
                "--ed-public-key", PUBLIC_FIXTURE, "--resources-dir", str(assets)])
            with patch.object(package_app, "ROOT", root), patch.object(package_app, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "yellow Dev"):
                    package_app.preflight(args)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
