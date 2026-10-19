#!/usr/bin/env python3
"""No-network self-test for fetch.py's three safety rules (Codex's reproduced risks, 2026-10-16).

    python3 scripts/speech_bench/test_fetch.py

Every subprocess call in fetch.py is replaced by a fake curl that writes the bytes a real curl
would, through whatever path it is given (so it would follow a planted symlink exactly as curl
does). Nothing is downloaded and nothing outside a fresh temporary folder is touched.

1. A file that fails its pin is moved aside with its bytes intact, never deleted.
2. A symlinked .part, .segNN or destination is refused before curl runs; its target is untouched.
3. Each receipt is appended as soon as its file is checked: a later failure keeps it, and a
   second run adds lines without rewriting the first run's.
"""
import glob
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("speech_bench_fetch_under_test", os.path.join(HERE, "fetch.py"))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)

TMP = tempfile.mkdtemp(prefix="speech-bench-fetch-test-")
calls = []
failures = []


def sha(data):
    return hashlib.sha256(data).hexdigest()


def model(mid, data):
    return {"id": mid, "file": mid + ".gguf", "bytes": len(data), "sha256": sha(data),
            "url": "https://invalid.example/%s.gguf" % mid}


def fake_curl(payloads, fail_on=()):
    """A curl stand-in: writes payloads[url] to the -o path (following symlinks, as curl does)."""
    def run(cmd, check=False, **kw):
        assert cmd[0] == "/usr/bin/curl", cmd
        calls.append(cmd)
        url = cmd[-1]
        if url in fail_on:
            raise RuntimeError("synthetic curl failure for " + url)
        with open(cmd[cmd.index("-o") + 1], "wb") as f:
            f.write(payloads[url])
    return run


def no_curl(cmd, *a, **kw):
    calls.append(cmd)
    raise AssertionError("curl must not run: %r" % (cmd,))


def check(name, ok, detail=""):
    print("%s  %s%s" % ("PASS" if ok else "FAIL", name, (": " + detail) if detail and not ok else ""))
    if not ok:
        failures.append(name)


def refused(fn, *args):
    try:
        fn(*args)
    except fetch.Refused:
        return True
    return False


def receipts_in(cache):
    path = os.path.join(cache, fetch.RECEIPTS)
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f]


def case_mismatch_is_moved_aside():
    cache = os.path.join(TMP, "mismatch")
    good = model("m1", b"pinned-bytes")
    dest = os.path.join(cache, "models", "m1", "m1.gguf")
    os.makedirs(os.path.dirname(dest))
    with open(dest, "wb") as f:
        f.write(b"someone else's file")
    fetch.subprocess.run = no_curl
    fetch.fetch_models(cache, {"models": [good]}, [], fetch.Receipts(cache))
    kept = glob.glob(dest + ".rejected-*")
    check("1a mismatched model file is not deleted", len(kept) == 1 and open(kept[0], "rb").read() == b"someone else's file",
          "kept=%r" % kept)
    check("1b mismatched model file is not used", not os.path.lexists(dest))
    rec = receipts_in(cache)
    check("1c receipt says unverified and where the file went", len(rec) == 1 and rec[0]["verified"] is False
          and rec[0]["moved_to"] == kept[0] if kept else False, "receipts=%r" % rec)

    # Same rule for a LibriSpeech archive.
    archive = os.path.join(cache, "downloads", "librispeech", "test-clean.tar.gz")
    os.makedirs(os.path.dirname(archive))
    with open(archive, "wb") as f:
        f.write(b"not the archive")
    ds = {"id": "test-clean", "file": "test-clean.tar.gz", "url": "https://invalid.example/a",
          "md5_openslr": hashlib.md5(b"the archive").hexdigest()}
    fetch.fetch_datasets(cache, {"datasets": [ds]}, fetch.Receipts(cache), [], 1)
    kept = glob.glob(archive + ".rejected-*")
    check("1d mismatched archive is kept aside, not deleted",
          len(kept) == 1 and open(kept[0], "rb").read() == b"not the archive" and not os.path.lexists(archive))
    check("1e no curl ran for files already present", not calls, "calls=%r" % calls)


def case_symlinks_are_refused():
    cache = os.path.join(TMP, "symlink")
    victim = os.path.join(TMP, "outside-the-cache.txt")
    with open(victim, "wb") as f:
        f.write(b"original")
    m = model("m2", b"pinned")
    d = os.path.join(cache, "models", "m2")
    os.makedirs(d)
    part = os.path.join(d, "m2.gguf.part")
    os.symlink(victim, part)
    fetch.subprocess.run = fake_curl({m["url"]: b"pinned"})
    calls.clear()
    ok = refused(fetch.fetch_models, cache, {"models": [m]}, [], fetch.Receipts(cache))
    check("2a symlinked .part is refused", ok)
    check("2b curl never ran, the file outside the cache is unchanged",
          not calls and open(victim, "rb").read() == b"original", "calls=%r" % calls)
    check("2c the .part symlink is left as it was, not replaced or moved into place",
          os.path.islink(part) and not os.path.lexists(os.path.join(d, "m2.gguf")))

    # A symlinked destination (even one pointing at the right bytes) is neither read nor replaced.
    good = os.path.join(TMP, "pinned-elsewhere.gguf")
    with open(good, "wb") as f:
        f.write(b"pinned")
    os.remove(part)
    dest = os.path.join(d, "m2.gguf")
    os.symlink(good, dest)
    ok = refused(fetch.fetch_models, cache, {"models": [m]}, [], fetch.Receipts(cache))
    check("2d symlinked destination is refused", ok and not calls)
    check("2e the link and its target are untouched", os.path.islink(dest) and open(good, "rb").read() == b"pinned")

    # Segmented dataset download: a planted .seg00 symlink is refused before any curl (even the HEAD).
    seg_dir = os.path.join(cache, "downloads", "librispeech")
    os.makedirs(seg_dir)
    seg = os.path.join(seg_dir, "test-other.tar.gz.seg00")
    os.symlink(victim, seg)
    fetch.subprocess.run = no_curl
    fetch.subprocess.Popen = no_curl
    ds = {"id": "test-other", "file": "test-other.tar.gz", "url": "https://invalid.example/b", "md5_openslr": "0" * 32}
    ok = refused(fetch.fetch_datasets, cache, {"datasets": [ds]}, fetch.Receipts(cache), ["https://mirror.invalid/12"], 2)
    check("2f symlinked .seg00 is refused before any curl", ok and not calls and open(victim, "rb").read() == b"original")

    # A symlinked cache folder component is refused too.
    os.makedirs(os.path.join(TMP, "elsewhere"))
    os.symlink(os.path.join(TMP, "elsewhere"), os.path.join(cache, "models", "m3"))
    ok = refused(fetch.fetch_models, cache, {"models": [model("m3", b"x")]}, [], fetch.Receipts(cache))
    check("2g symlinked cache folder is refused", ok and not os.listdir(os.path.join(TMP, "elsewhere")))


def case_receipts_are_appended_at_once():
    cache = os.path.join(TMP, "receipts")
    first, second = model("first", b"first-bytes"), model("second", b"second-bytes")
    harness = os.path.join(TMP, "harness")
    os.makedirs(harness)
    with open(os.path.join(harness, "models.json"), "w") as f:
        json.dump({"models": [first, second], "datasets": []}, f)
    fetch.HERE = harness
    fetch.subprocess.run = fake_curl({first["url"]: b"first-bytes", second["url"]: b"second-bytes"},
                                     fail_on={second["url"]})
    calls.clear()
    old_argv = sys.argv
    sys.argv = ["fetch.py", "--cache", cache, "--only", "models"]
    try:
        try:
            fetch.main()
            raised = False
        except RuntimeError:
            raised = True
    finally:
        sys.argv = old_argv
    rec = receipts_in(cache)
    check("3a a later failure keeps the first file's receipt", raised and len(rec) == 1 and rec[0]["id"] == "first"
          and rec[0]["verified"] and rec[0]["source"].startswith("download:"), "receipts=%r" % rec)
    check("3b the receipt binds fetch.py and models.json", rec and len(rec[0].get("fetch_py_sha256", "")) == 64
          and len(rec[0].get("models_json_sha256", "")) == 64)

    fetch.subprocess.run = fake_curl({first["url"]: b"first-bytes", second["url"]: b"second-bytes"})
    sys.argv = ["fetch.py", "--cache", cache, "--only", "models"]
    try:
        fetch.main()
    finally:
        sys.argv = old_argv
    rec2 = receipts_in(cache)
    check("3c a second run appends; the first run's line is unchanged",
          len(rec2) == 3 and rec2[0] == rec[0] and rec2[1]["id"] == "first" and rec2[1]["source"] == "existing"
          and rec2[2]["id"] == "second" and rec2[2]["source"].startswith("download:"), "receipts=%r" % rec2)


def main():
    real_run, real_popen, real_here = fetch.subprocess.run, fetch.subprocess.Popen, fetch.HERE
    try:
        for case in (case_mismatch_is_moved_aside, case_symlinks_are_refused, case_receipts_are_appended_at_once):
            calls.clear()
            case()
    finally:
        fetch.subprocess.run, fetch.subprocess.Popen, fetch.HERE = real_run, real_popen, real_here
        shutil.rmtree(TMP, ignore_errors=True)
    if failures:
        print("FAILED: %d check(s): %s" % (len(failures), ", ".join(failures)))
        sys.exit(1)
    print("OK: fetch.py keeps mismatched files, refuses symlinks, appends receipts at once (no network)")


if __name__ == "__main__":
    main()
