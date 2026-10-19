#!/usr/bin/env python3
"""Build/stage the pinned native runtime from explicit local inputs; no downloads."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from orukeet.assets import HERE, LIBRARIES, MODEL_NAME, checked_sdk, inspect_native, validate_assets, write_manifest


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not all(p.is_absolute() for p in (args.sdk, args.model, args.output)):
        raise RuntimeError("SDK, model and fresh output must be explicit absolute paths")
    if args.output.exists() or args.output.is_symlink():
        raise RuntimeError("Stage output must be fresh; existing assets are never overwritten")
    sdk, model = checked_sdk(args.sdk, args.model)
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "lib").mkdir()
    for name in LIBRARIES:
        shutil.copyfile(sdk / "lib" / name, args.output / "lib" / name)
    shutil.copyfile(model, args.output / MODEL_NAME)
    shutil.copyfile(HERE / "sdk-build.json", args.output / "sdk-build.json")
    shutil.copytree(HERE / "licenses", args.output / "licenses")
    run("xcrun", "clang++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Wpedantic", "-Werror",
        "-pthread", "-arch", "arm64", "-mmacosx-version-min=14.0",
        "-I", str(sdk / "include"), str(HERE / "orukeet_worker.cpp"),
        "-L", str(args.output / "lib"), "-lnemo_speech_asr_c",
        "-Wl,-rpath,@executable_path/lib", "-o", str(args.output / "orukeet-worker"))
    inspect_native(args.output, run)
    write_manifest(args.output)
    validate_assets(args.output)
    print(args.output)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Orukeet staging stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
