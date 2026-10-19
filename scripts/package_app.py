#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from update_config import update_configuration
from orukeet.assets import MODEL_NAME, inspect_native, sha256 as asset_sha256, validate_assets, write_manifest

ROOT = Path(__file__).resolve().parents[1]



def run(*args: str, cwd: Path = ROOT) -> str:
    """Stop on the first failed build/sign/notary step; never infer success from an output file."""
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}):\n{result.stderr or result.stdout}")
    return result.stdout.strip()


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__ or "Package Tokens without installing or launching it.")
    p.add_argument("--mode", choices=("preview", "dev", "distribution"), default="preview",
                   help="preview builds an isolated ad-hoc community app; dev explicitly enables QA routes")
    p.add_argument("--version", default="0.1.0")
    p.add_argument("--build-number", default="1")
    p.add_argument("--identity", help="Your signing identity; preview uses ad-hoc signing when omitted")
    p.add_argument("--notary-profile", help="Existing notarytool Keychain profile; no credentials in source")
    p.add_argument("--resources-dir", type=Path, help="Reviewed app assets to embed in Contents/Resources")
    p.add_argument("--enable-orukeet", action="store_true", help="Bundle the pinned local native Orukeet backend")
    p.add_argument("--orukeet-assets", type=Path, help="Fresh verified stage_assets.py output; required with --enable-orukeet")
    p.add_argument("--transcribe-worker", type=Path,
                   help="Directory from scripts/transcribe/build_worker.sh; makes Parakeet v3 the default")
    p.add_argument("--apple-only", action="store_true", help="Explicit minimal package using only Apple speech")
    p.add_argument("--orukeet-model-url", help="Leave the weights out of the bundle; the app downloads and verifies them from this https URL")
    p.add_argument("--binary", type=Path, help="Preview-only prebuilt binary, useful for bundle fixture checks")
    p.add_argument("--feed-url", help="Public HTTPS Sparkle appcast URL; required for distribution")
    p.add_argument("--ed-public-key", help="Public base64 Ed25519 update key, never a private key")
    return p


# Preflight — distribution requires real credentials and a reproducible source

def preflight(args: argparse.Namespace) -> str:
    check_orukeet_options(args)
    speech_configuration(args)
    update_configuration(getattr(args, "feed_url", None), getattr(args, "ed_public_key", None),
                         required=args.mode == "distribution")
    if args.mode == "distribution":
        if not args.resources_dir or not args.resources_dir.is_dir():
            raise RuntimeError("Distribution requires --resources-dir with reviewed public app assets.")
        for name in ("TTT.icns", "WaveIdentity"):
            if not (args.resources_dir / name).exists():
                raise RuntimeError(f"Missing reviewed distribution asset: {name}")
        if args.resources_dir.resolve() == (ROOT / "Resources/Dev").resolve():
            raise RuntimeError("Distribution cannot use the yellow Dev asset directory.")
    if sys.platform != "darwin":
        raise RuntimeError("macOS is required for application packaging and code signing.")
    sha = run("git", "rev-parse", "HEAD")
    if args.mode in ("dev", "distribution") or (args.mode == "preview" and args.identity):
        if args.binary:
            raise RuntimeError("Signed candidates must build from source; --binary is preview-only.")
        prefix = "Developer ID Application:" if args.mode == "distribution" else "Apple Development:"
        if not args.identity or not args.identity.startswith(prefix):
            raise RuntimeError(f"{args.mode} requires an exact {prefix} identity.")
        if args.mode == "distribution" and not args.notary_profile:
            raise RuntimeError("Distribution requires an existing --notary-profile.")
        if args.mode == "distribution" and run("git", "status", "--porcelain"):
            raise RuntimeError("Commit/review the working tree before a distribution build.")
        identities = run("security", "find-identity", "-v", "-p", "codesigning")
        if f'"{args.identity}"' not in identities:
            raise RuntimeError("Requested signing identity is not available.")
    if args.resources_dir and not args.resources_dir.is_dir():
        raise RuntimeError("--resources-dir must be an existing directory of reviewed app assets.")
    if args.mode in ("dev",):
        if not args.resources_dir:
            raise RuntimeError("Local apps require --resources-dir with the reviewed channel icon and app assets.")
        for name in ("TTT.icns", "WaveIdentity"):
            if not (args.resources_dir / name).exists():
                raise RuntimeError(f"Missing local app asset: {name}")
    return sha


def check_orukeet_options(args):
    enabled = getattr(args, "enable_orukeet", False)
    assets = getattr(args, "orukeet_assets", None)
    if enabled and args.mode == "distribution":
        raise RuntimeError(
            "Orukeet distribution is disabled pending independent qualification of the rebuilt SDK. "
            "The prior SDK was affected by CVE-2026-1260. Verify the replacement before distributing it. "
            "Preview/dev builds remain available for local review of the pinned inputs.")
    if enabled != bool(assets):
        raise RuntimeError("Orukeet requires both --enable-orukeet and --orukeet-assets.")
    if args.resources_dir and (args.resources_dir / "Orukeet").exists():
        raise RuntimeError("Orukeet assets must use the explicit verified --orukeet-assets route.")
    if enabled:
        validate_assets(assets)
        inspect_native(assets, run)
    url = getattr(args, "orukeet_model_url", None)
    if url:
        if not enabled:
            raise RuntimeError("--orukeet-model-url needs --enable-orukeet (the worker still ships).")
        if not url.startswith("https://") and not (url.startswith("file:///") and args.mode != "distribution"):
            raise RuntimeError("--orukeet-model-url must be https (file:// only outside distribution).")


def speech_configuration(args):
    """A normal community package must include the Parakeet runtime.

    Apple-only packages require an explicit flag; omitting a worker must never
    silently change the user's requested default into Apple speech.
    """
    transcribe = getattr(args, "transcribe_worker", None)
    orukeet = getattr(args, "enable_orukeet", False)
    apple_only = getattr(args, "apple_only", False)
    if apple_only and (transcribe or orukeet):
        raise RuntimeError("--apple-only cannot be combined with local speech workers.")
    if transcribe:
        source = Path(transcribe).resolve(strict=True)
        for name in ("transcribe-worker", "LICENSE-transcribe.cpp", "THIRD-PARTY-LICENSES-transcribe.cpp.md"):
            path = source / name
            if path.is_symlink() or not path.is_file():
                raise RuntimeError("--transcribe-worker is missing a regular " + name)
        return {"TokensDefaultSpeechModel": "parakeet-tdt-0.6b-v3"}
    if orukeet:
        return {"TokensDefaultSpeechModel": "orukeet"}
    if apple_only:
        return {"TokensDefaultSpeechModel": "apple"}
    raise RuntimeError("Community packages default to Parakeet v3. Supply --transcribe-worker "
                       "from scripts/transcribe/build_worker.sh, or explicitly choose --apple-only.")


# Source identity — dirty development trees need a content identity, not HEAD


def source_manifest(resources_dir=None, orukeet_assets=None, transcribe_worker=None):
    paths = [ROOT / name for name in ("Package.swift", "Package.resolved") if (ROOT / name).is_file()]
    for name in ("Sources", "Tests", "scripts", "Resources"):
        paths.extend(p for p in (ROOT / name).rglob("*") if p.is_file()
                     and not any(x.startswith(".") or x == "__pycache__" for x in p.relative_to(ROOT).parts))
    rows = [{"path": str(p.relative_to(ROOT)), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in sorted(set(paths))]
    if resources_dir:
        for p in sorted(resources_dir.rglob("*")):
            # Markdown notes are not copied into the app (see assemble), so they are not assets.
            if p.is_file() and p.suffix != ".md":
                rows.append({"path": "bundle-assets/" + str(p.relative_to(resources_dir)),
                             "sha256": hashlib.sha256(p.read_bytes()).hexdigest()})
    if orukeet_assets:
        for p in sorted(orukeet_assets.rglob("*")):
            if p.is_file():
                rows.append({"path": "orukeet-assets/" + str(p.relative_to(orukeet_assets)),
                             "sha256": asset_sha256(p)})
    if transcribe_worker:
        for name in ("transcribe-worker", "LICENSE-transcribe.cpp", "THIRD-PARTY-LICENSES-transcribe.cpp.md"):
            rows.append({"path": "transcribe-assets/" + name,
                         "sha256": asset_sha256(Path(transcribe_worker) / name)})
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "files": rows}


# Bundle assembly — fresh destination, explicit identity, no installation
#
# :)
#
#
def assemble(args: argparse.Namespace, sha: str, manifest: dict) -> tuple[Path, Path]:
    update_fields = update_configuration(getattr(args, "feed_url", None), getattr(args, "ed_public_key", None),
                                         required=args.mode == "distribution")
    if args.binary:
        binary = args.binary.resolve(strict=True)
        resources = []
    else:
        package_description = json.loads(run("swift", "package", "dump-package"))
        if not any(p["name"] == "Tokens" and "executable" in p["type"] for p in package_description["products"]):
            raise RuntimeError("Tokens executable target is not integrated yet; core tests alone cannot produce an app.")
        sdk_version = run("xcrun", "--sdk", "macosx", "--show-sdk-version")
        # Explicit platform metadata avoids inheriting obsolete SDK behavior in AppKit.
        run("swift", "build", "--jobs", "2", "-c", "release", "--product", "Tokens",
            "-Xlinker", "-platform_version", "-Xlinker", "macos",
            "-Xlinker", "14.0", "-Xlinker", sdk_version)
        binary_dir = Path(run("swift", "build", "-c", "release", "--show-bin-path"))
        binary = binary_dir / "Tokens"
        resources = list(binary_dir.glob("*.bundle"))
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError("The build did not produce an executable Tokens binary.")

    # Only the pinned Sparkle framework may be bundled from SwiftPM's build output.
    linked = run("otool", "-L", str(binary)).splitlines()[1:]
    external = [line.strip().split(" (", 1)[0] for line in linked
                if not line.strip().startswith(("/System/Library/", "/usr/lib/"))]
    sparkle_link = "@rpath/Sparkle.framework/Versions/B/Sparkle"
    unexpected = [path for path in external if path != sparkle_link]
    if unexpected:
        raise RuntimeError("Unreviewed external linkage: " + ", ".join(unexpected))

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = ROOT / "dist" / f"{stamp}-{args.mode}-{sha[:7]}"
    output.mkdir(parents=True, exist_ok=False)
    preview = args.mode == "preview"
    name = ("Tokens Community" if preview else "Tokens Community Dev" if args.mode == "dev"
            else "Tokens Community")
    app = output / f"{name}.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    executable = contents / "MacOS" / "Tokens"
    shutil.copyfile(binary, executable)
    executable.chmod(0o755)
    # Strip build-machine debug paths from every packaged channel.
    run("strip", "-S", "-x", str(executable))
    shipped = executable.read_bytes()
    if b"/Users/" in shipped or str(ROOT).encode() in shipped:
        raise RuntimeError("Packaged binary still contains build-machine paths after strip.")
    for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copyfile(ROOT / notice, contents / "Resources" / notice)
    if sparkle_link in external:
        framework = binary.parent / "Sparkle.framework"
        if not framework.is_dir():
            raise RuntimeError("Sparkle linked but framework absent beside the built executable.")
        (contents / "Frameworks").mkdir()
        shutil.copytree(framework, contents / "Frameworks/Sparkle.framework", symlinks=True)

    # Bundle.module searches Bundle.main.resourceURL for package resource bundles.
    # Keep them only in Contents/Resources: root-level sidecars make codesign reject the app.
    for resource in resources:
        target = contents / "Resources" / resource.name
        shutil.copytree(resource, target)
    if args.resources_dir:
        for resource in args.resources_dir.iterdir():
            target = contents / "Resources" / resource.name
            if target.exists():
                raise RuntimeError(f"Duplicate app resource: {resource.name}")
            # Working notes (Markdown provenance files) stay in the repo; they name people and
            # internal folders and are not part of the app a stranger downloads.
            if resource.is_dir():
                shutil.copytree(resource, target, ignore=shutil.ignore_patterns("*.md"))
            elif resource.suffix != ".md":
                shutil.copy2(resource, target)
    if getattr(args, "enable_orukeet", False):
        # Keep notices verbatim, including Markdown licenses excluded from ordinary UI assets.
        source = args.orukeet_assets
        validate_assets(source)
        target = contents / "Resources/Orukeet"
        shutil.copytree(source, target)
        if validate_assets(target) != validate_assets(source):
            raise RuntimeError("Orukeet asset copy differs from its verified source")
        if getattr(args, "orukeet_model_url", None):
            # Build 77: the weights download after install; the signed worker and libraries stay.
            (target / MODEL_NAME).unlink()
            write_manifest(target)
            validate_assets(target, model_external=True)

    info = {
        "CFBundleName": name, "CFBundleDisplayName": name,
        "CFBundleIdentifier": ("com.tinkr.tokens.community.preview" if preview else
                               "com.tinkr.tokens.community.dev.macos" if args.mode == "dev" else
                               "com.tinkr.tokens.community.macos"),
        "CFBundleExecutable": "Tokens", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": args.version, "CFBundleVersion": args.build_number,
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "SUEnableAutomaticChecks": False, "SUSendProfileInfo": False,
        "NSMicrophoneUsageDescription": "Tokens uses the microphone for Talk and optional background listening.",
        "NSSpeechRecognitionUsageDescription": "Tokens converts speech into text on this Mac.",
        "TokensSourceCommit": sha, "TokensDistributionMode": args.mode,
        "TokensSourceSHA256": manifest["sha256"],
    }
    info.update(update_fields)
    info.update(speech_configuration(args))
    if getattr(args, "enable_orukeet", False):
        info["TokensOrukeetEnabled"] = True
    if getattr(args, "orukeet_model_url", None):
        info["TokensOrukeetModelURL"] = args.orukeet_model_url
    if (contents / "Resources/TTT.icns").is_file():
        info["CFBundleIconFile"] = "TTT.icns"
    if args.mode == "dev":
        # Existing stored keys intentionally survive. Empty promotion SHA disables the
        # old-tree merge button: a dirty rebuilt candidate must not run that script.
        info.update(TTTDevChannel=True, TTTDevSourceCommit="")
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (output / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return app, output


# Signing and notarization — a preview is never a public download
#
# :)
#
#
def sign_and_verify(args: argparse.Namespace, app: Path, output: Path) -> dict:
    entitlements = output / "audio.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.device.audio-input": True}))
    distribution = args.mode == "distribution"
    identity = args.identity or "-"
    extra = ["--timestamp"] if distribution else ["--timestamp=none"]
    # Ad hoc preview has no Team ID shared with Sparkle. Hardened library validation
    # would reject that local bundle; real signed modes retain runtime protection.
    runtime = [] if args.mode == "preview" and not args.identity else ["--options", "runtime"]
    orukeet = app / "Contents/Resources/Orukeet"
    orukeet_manifest = None
    external = bool(getattr(args, "orukeet_model_url", None))
    if getattr(args, "enable_orukeet", False):
        validate_assets(orukeet, model_external=external)
        # Explicit dependencies first, then worker. No microphone entitlements on native code.
        for target in inspect_native(orukeet, run):
            run("codesign", "--force", *runtime, "--sign", identity, *extra, str(target))
            run("codesign", "--verify", "--strict", str(target))
        # Signing changes Mach-O bytes; the runtime validates final signed hashes.
        orukeet_manifest = write_manifest(orukeet)
        validate_assets(orukeet, unsigned=False, model_external=external)
        inspect_native(orukeet, run)
    elif orukeet.exists():
        raise RuntimeError("Unrequested Orukeet code found in candidate")
    transcribe_receipt = None
    transcribe_source = getattr(args, "transcribe_worker", None)
    if transcribe_source:
        # Build 79: one static transcribe.cpp worker for the downloadable models (no dylibs).
        source = Path(transcribe_source).resolve(strict=True)
        target = app / "Contents/Resources/Transcribe"
        target.mkdir(parents=True)
        for name in ("transcribe-worker", "LICENSE-transcribe.cpp", "THIRD-PARTY-LICENSES-transcribe.cpp.md"):
            if not (source / name).is_file():
                raise RuntimeError("--transcribe-worker is missing " + name)
            shutil.copy2(source / name, target / name)
        bound_files = {row["path"]: row["sha256"] for row in
                       json.loads((output / "source-manifest.json").read_text())["files"]}
        for name in ("transcribe-worker", "LICENSE-transcribe.cpp", "THIRD-PARTY-LICENSES-transcribe.cpp.md"):
            if asset_sha256(target / name) != bound_files.get("transcribe-assets/" + name):
                raise RuntimeError("Transcribe staged input changed after source manifest: " + name)
        worker = target / "transcribe-worker"
        if run("lipo", "-archs", str(worker)).strip() != "arm64":
            raise RuntimeError("transcribe-worker is not arm64")
        linked = [line.strip().split(" (", 1)[0] for line in run("otool", "-L", str(worker)).splitlines()[1:]]
        if any(not path.startswith(("/usr/lib/", "/System/Library/")) for path in linked):
            raise RuntimeError("transcribe-worker links outside the system: " + ", ".join(linked))
        run("strip", "-S", "-x", str(worker))
        if b"/Users/" in worker.read_bytes() or str(ROOT).encode() in worker.read_bytes():
            raise RuntimeError("transcribe-worker contains build-machine paths; rebuild with prefix maps")
        run("codesign", "--force", *runtime, "--sign", identity, *extra, str(worker))
        run("codesign", "--verify", "--strict", str(worker))
        transcribe_receipt = {"worker_sha256": asset_sha256(worker),
                              "license_sha256": asset_sha256(target / "LICENSE-transcribe.cpp"),
                              "third_party_notices_sha256": asset_sha256(target / "THIRD-PARTY-LICENSES-transcribe.cpp.md")}
    framework = app / "Contents/Frameworks/Sparkle.framework"
    if framework.exists():
        # Sign nested services and updater first, then the enclosing framework and app.
        # Preserve Sparkle's helper entitlements; app microphone rights stay on the app.
        version = framework / "Versions/Current"
        nested = [p for p in version.rglob("*") if not p.is_symlink()
                  and p.suffix in (".xpc", ".app") and p.is_dir()]
        autoupdate = version / "Autoupdate"
        if autoupdate.is_file():
            nested.append(autoupdate)
        for target in sorted(nested, key=lambda p: len(p.parts), reverse=True) + [framework]:
            run("codesign", "--force", *runtime, "--preserve-metadata=entitlements",
                "--sign", identity, *extra, str(target))
    run("codesign", "--force", *runtime, "--entitlements", str(entitlements),
        "--sign", identity, *extra, str(app))
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    receipt = {"mode": args.mode, "app": str(app), "signature_verified": True,
               "fixture_binary": bool(args.binary),
               "source_commit": run("git", "rev-parse", "HEAD"),
               "source_dirty": bool(run("git", "status", "--porcelain")),
               "notarized": False, "gatekeeper_accepted": False,
               "native_behavior_verified": False, "installed": False}
    receipt.update(source_sha256=json.loads((output / "source-manifest.json").read_text())["sha256"],
                   binary_sha256=hashlib.sha256((app / "Contents/MacOS/Tokens").read_bytes()).hexdigest(),
                   signing_identity=identity,
                   bundle_identifier=plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"])
    if orukeet_manifest:
        receipt.update(orukeet_enabled=True, orukeet_asset_manifest=orukeet_manifest,
                       orukeet_source_assets={"path": str(args.orukeet_assets.resolve(strict=True)),
                                              "manifest_sha256": asset_sha256(args.orukeet_assets / "asset-manifest.json")},
                       orukeet_native_behavior_verified=False,
                       orukeet_model_url=getattr(args, "orukeet_model_url", None))
    if transcribe_receipt:
        receipt.update(transcribe_worker=transcribe_receipt, default_speech_model="parakeet-tdt-0.6b-v3")
    (output / "signature.txt").write_text(subprocess.run(
        ["codesign", "-dv", "--verbose=4", str(app)], text=True, capture_output=True, check=True).stderr)
    (output / "linked-libraries.txt").write_text(run("otool", "-L", str(app / "Contents/MacOS/Tokens")) + "\n")
    (output / "platform.txt").write_text(run("xcrun", "vtool", "-show-build", str(app / "Contents/MacOS/Tokens")) + "\n")
    if distribution:
        upload = output / "notary-upload.zip"
        run("ditto", "-c", "-k", "--keepParent", str(app), str(upload))
        report = json.loads(run("xcrun", "notarytool", "submit", str(upload), "--wait",
                                "--keychain-profile", args.notary_profile, "--output-format", "json"))
        (output / "notary-result.json").write_text(json.dumps(report, indent=2))
        if report.get("status") != "Accepted":
            raise RuntimeError("Apple did not accept notarization; this is not a release artifact.")
        run("xcrun", "stapler", "staple", str(app))
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
        archive = output / "Tokens.zip"
        run("ditto", "-c", "-k", "--keepParent", str(app), str(archive))
        receipt.update(notarized=True, gatekeeper_accepted=True, archive=str(archive))
    (output / "package-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main() -> int:
    args = parser().parse_args()
    try:
        sha = preflight(args)
        manifest = source_manifest(args.resources_dir, args.orukeet_assets, args.transcribe_worker)
        app, output = assemble(args, sha, manifest)
        if source_manifest(args.resources_dir, args.orukeet_assets, args.transcribe_worker) != manifest:
            raise RuntimeError("Source/assets changed while building; candidate cannot be signed as this revision.")
        print(json.dumps(sign_and_verify(args, app, output), indent=2))
        return 0
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"Packaging stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
