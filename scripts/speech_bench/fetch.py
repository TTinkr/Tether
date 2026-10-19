#!/usr/bin/env python3
"""Fetch the pinned model weights and LibriSpeech archives into the bench cache, verifying hashes.

Every model file must match the sha256 and byte size pinned in models.json (copied from
SpeechModelCatalog.swift). LibriSpeech archives must match OpenSLR's published md5;
their sha256 is recorded in <cache>/downloads/librispeech/checksums.json and later in manifest.json.

Safety rules (Codex's reproduced risks, 2026-10-16):
- A file that fails its pin is never deleted and never used: it is moved aside to
  <file>.rejected-<UTC time> in the same folder, and the run fails.
- A symlink is never followed or replaced: a symlinked destination, `.part`, `.segNN` file, cache
  folder or receipt file stops the fetch with REFUSED. One fetch at a time per cache (a lock file).
- Each acquisition receipt is appended to <cache>/fetch-receipts.jsonl (and fsynced) as soon as
  that file is checked, so a later failure cannot lose it, and earlier receipts are never rewritten.

--local-copy PATH lets an already-downloaded file stand in for a download: it is hashed first and
cloned (APFS copy-on-write, no extra disk) only when its sha256 and size match the pin.

openslr.org itself served ~130 KB/s on 2026-10-16, so --mirror (the official mirrors listed on
https://www.openslr.org/12/) plus --segments downloads byte ranges in parallel; the OpenSLR md5
check is the same either way.

Self-test (no network): python3 scripts/speech_bench/test_fetch.py

Usage: python3 -I fetch.py [--cache DIR] [--only models|datasets] [--local-copy PATH ...]
                           [--mirror URL ... --segments N]
"""
import argparse
import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CACHE = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "cache", "speech-bench"))
RECEIPTS = "fetch-receipts.jsonl"


class Refused(Exception):
    """A path the fetcher will not touch (symlink, non-regular file, busy cache)."""


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def digest(path, algo="sha256", follow=False):
    """Hash a file; cache paths are opened without following a symlink (follow=True: --local-copy)."""
    h = hashlib.new(algo)
    fd = os.open(path, os.O_RDONLY | (0 if follow else os.O_NOFOLLOW))
    with os.fdopen(fd, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def no_symlink(path):
    """Refuse a symlink (dangling or not) or anything that is not a regular file. Absent is fine."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(st.st_mode):
        raise Refused("refusing to follow or replace a symlink: %s" % path)
    if not stat.S_ISREG(st.st_mode):
        raise Refused("refusing a non-regular file: %s" % path)
    return True


def ensure_dir(root, *parts):
    """Create root/parts..., refusing any component below root that is a symlink or not a folder."""
    path = root
    os.makedirs(root, exist_ok=True)
    for part in parts:
        path = os.path.join(path, part)
        try:
            os.mkdir(path)
        except FileExistsError:
            pass
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
            raise Refused("refusing a symlinked or non-folder cache path: %s" % path)
    return path


def move_aside(path):
    """Keep a file that failed its pin, renamed beside itself; never delete it."""
    base = "%s.rejected-%s" % (path, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    target, n = base, 1
    while os.path.lexists(target):
        target, n = "%s-%d" % (base, n), n + 1
    os.rename(path, target)
    return target


def touch_regular(path):
    """Create path as an empty regular file if absent, without following a symlink planted there."""
    no_symlink(path)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o644)
    except OSError as e:  # ELOOP: a symlink appeared after the check
        raise Refused("refusing to follow a symlink: %s (%s)" % (path, e))
    os.close(fd)
    no_symlink(path)


def replace_checked(part, dest):
    """Rename a finished download into place; neither side may be (or have become) a symlink."""
    no_symlink(part)
    no_symlink(dest)
    os.replace(part, dest)


class Receipts:
    """Append-only acquisition log: one JSON line per checked file, written and fsynced at once."""

    def __init__(self, cache):
        self.path = os.path.join(cache, RECEIPTS)
        self.records = []
        self.binding = {"fetch_py_sha256": digest(os.path.abspath(__file__)),
                        "models_json_sha256": digest(os.path.join(HERE, "models.json"))}

    def append(self, rec):
        rec = dict(rec, **self.binding)
        fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o644)
        try:
            os.write(fd, (json.dumps(rec) + "\n").encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        self.records.append(rec)
        print(json.dumps(rec), flush=True)


def lock_cache(cache):
    """One fetcher per cache: two would share and truncate the same .part files."""
    fd = os.open(os.path.join(cache, ".fetch.lock"), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise Refused("another fetch.py is using %s" % cache)
    return fd


def write_json_atomic(path, obj):
    no_symlink(path)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def curl(url, dest):
    part = dest + ".part"
    no_symlink(dest)
    touch_regular(part)  # a leftover regular .part resumes (-C -); a symlinked one is refused
    cmd = ["/usr/bin/curl", "-L", "--fail", "--silent", "--show-error", "--retry", "3",
           "-C", "-", "-o", part, url]
    t0 = time.time()
    subprocess.run(cmd, check=True)
    replace_checked(part, dest)
    return time.time() - t0


def curl_segmented(urls, dest, segments):
    """Parallel byte-range download across official mirrors (same bytes; md5 decides)."""
    part = dest + ".part"
    seg_paths = ["%s.seg%02d" % (dest, i) for i in range(segments)]
    no_symlink(dest)
    no_symlink(part)
    for p in seg_paths:
        no_symlink(p)
    out = subprocess.run(["/usr/bin/curl", "-sLI", "--fail", urls[0]], check=True, capture_output=True, text=True).stdout
    size = int([l.split(":")[1] for l in out.splitlines() if l.lower().startswith("content-length")][-1])
    step = -(-size // segments)
    t0 = time.time()
    procs = []
    for i, seg in enumerate(seg_paths):
        lo, hi = i * step, min(size, (i + 1) * step) - 1
        url = urls[i % len(urls)]
        touch_regular(seg)
        procs.append((seg, lo, hi, subprocess.Popen(
            ["/usr/bin/curl", "-L", "--fail", "--silent", "--show-error", "--retry", "5",
             "-r", "%d-%d" % (lo, hi), "-o", seg, url])))
    for seg, lo, hi, p in procs:
        if p.wait() != 0 or not no_symlink(seg) or os.path.getsize(seg) != hi - lo + 1:
            raise RuntimeError("segment failed: " + seg)
    fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as f:
        for seg, _, _, _ in procs:
            g_fd = os.open(seg, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(g_fd, "rb") as g:
                for chunk in iter(lambda: g.read(1 << 20), b""):
                    f.write(chunk)
            os.remove(seg)  # our own byte-range piece, already copied into .part
    replace_checked(part, dest)
    return time.time() - t0


def fetch_models(cache, spec, local_copies, receipts):
    for m in spec["models"]:
        d = ensure_dir(cache, "models", m["id"])
        dest = os.path.join(d, m["file"])
        source = "existing"
        if not no_symlink(dest):
            local = next((p for p in local_copies if os.path.basename(p) == m["file"]), None)
            if local and os.path.getsize(local) == m["bytes"] and digest(local, follow=True) == m["sha256"]:
                subprocess.run(["/bin/cp", "-c", local, dest], check=True)
                source = "local-copy:" + local
            else:
                secs = curl(m["url"], dest)
                source = "download:%s (%.1fs)" % (m["url"], secs)
        no_symlink(dest)
        size = os.path.getsize(dest)
        sha = digest(dest)
        ok = size == m["bytes"] and sha == m["sha256"]
        rec = {"id": m["id"], "file": dest, "bytes": size, "sha256": sha, "pinned_sha256": m["sha256"],
               "verified": ok, "source": source, "checked_utc": utc()}
        if not ok:
            rec["moved_to"] = move_aside(dest)
        receipts.append(rec)
        if not ok:
            print("REFUSED: hash or size mismatch for %s; kept as %s" % (m["id"], rec["moved_to"]), file=sys.stderr)


def fetch_datasets(cache, spec, receipts, mirrors, segments):
    d = ensure_dir(cache, "downloads", "librispeech")
    sums_path = os.path.join(d, "checksums.json")
    sums = {}
    if no_symlink(sums_path):
        with open(sums_path) as f:
            sums = json.load(f)
    for ds in spec["datasets"]:
        dest = os.path.join(d, ds["file"])
        source = "existing"
        if not no_symlink(dest):
            if mirrors:
                urls = [m.rstrip("/") + "/" + ds["file"] for m in mirrors]
                secs = curl_segmented(urls, dest, segments)
                source = "download:%s x%d segments (%.1fs)" % (",".join(urls), segments, secs)
            else:
                secs = curl(ds["url"], dest)
                source = "download:%s (%.1fs)" % (ds["url"], secs)
        no_symlink(dest)
        md5 = digest(dest, "md5")
        sha = digest(dest)
        ok = md5 == ds["md5_openslr"] and (ds["file"] not in sums or sums[ds["file"]]["sha256"] == sha)
        rec = {"id": ds["id"], "file": dest, "bytes": os.path.getsize(dest), "md5": md5,
               "md5_openslr": ds["md5_openslr"], "sha256": sha, "verified": ok, "source": source,
               "checked_utc": utc()}
        if not ok:
            rec["moved_to"] = move_aside(dest)
        receipts.append(rec)
        if not ok:
            print("REFUSED: checksum mismatch for %s; kept as %s" % (ds["id"], rec["moved_to"]), file=sys.stderr)
            continue
        sums[ds["file"]] = {"sha256": sha, "md5": md5, "bytes": rec["bytes"]}
        write_json_atomic(sums_path, sums)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=DEFAULT_CACHE)
    ap.add_argument("--only", choices=["models", "datasets"])
    ap.add_argument("--local-copy", action="append", default=[])
    ap.add_argument("--mirror", action="append", default=[],
                    help="official OpenSLR mirror base for resources/12, e.g. https://openslr.elda.org/resources/12")
    ap.add_argument("--segments", type=int, default=8)
    a = ap.parse_args()
    with open(os.path.join(HERE, "models.json")) as f:
        spec = json.load(f)
    try:
        cache = ensure_dir(os.path.abspath(a.cache))
        lock = lock_cache(cache)
        try:
            no_symlink(os.path.join(cache, RECEIPTS))
            receipts = Receipts(cache)
            if a.only in (None, "datasets"):
                fetch_datasets(cache, spec, receipts, a.mirror, a.segments)
            if a.only in (None, "models"):
                fetch_models(cache, spec, a.local_copy, receipts)
        finally:
            os.close(lock)
    except Refused as e:
        sys.exit("REFUSED: %s" % e)
    bad = [r["id"] for r in receipts.records if not r["verified"]]
    if bad:
        print("FAILED verification: " + ", ".join(bad), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
