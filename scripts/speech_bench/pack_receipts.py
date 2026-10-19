#!/usr/bin/env python3
"""Check a run's raw receipts into its results folder as one small, reproducible archive.

    python3 -I scripts/speech_bench/pack_receipts.py scripts/speech_bench/results/<run> [--cache DIR]

bench.py writes the raw receipts (every ready/result line verbatim with its timing, the workers'
stderr, env.json) to <cache>/raw/<run id>/ and pins each file in results/<run>/receipts.sha256.
This packs exactly those files, each re-checked against its pin, into
results/<run>/raw-receipts.tar.gz (members named as in receipts.sha256, fixed owner and times,
gzip without a timestamp) and writes its sha256 to raw-receipts.tar.gz.sha256. An existing
archive is never overwritten with different bytes.

verify.py reads receipts from this archive (in memory, nothing is extracted), and to_swift.py
refuses a run without it. Stdlib only, so the system python3 runs it.
"""
import argparse
import gzip
import hashlib
import io
import os
import posixpath
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CACHE = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "cache", "speech-bench"))
ARCHIVE = "raw-receipts.tar.gz"
ARCHIVE_SHA = ARCHIVE + ".sha256"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def listing(results):
    """(sha256, relative path) for every raw receipt bench.py pinned for this run."""
    out = []
    with open(os.path.join(results, "receipts.sha256")) as f:
        for line in f:
            h, rel = line.rstrip("\n").split("  ", 1)
            out.append((h, rel))
    return out


def safe_name(name):
    return (name == posixpath.normpath(name) and not name.startswith(("/", "../")) and ".." not in name.split("/"))


def build(results, cache):
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, compresslevel=9, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for h, rel in listing(results):
                if not safe_name(rel):
                    raise ValueError("unsafe receipt path: " + rel)
                with open(os.path.join(cache, rel), "rb") as f:
                    data = f.read()
                if sha256(data) != h:
                    raise ValueError("receipt missing or changed: " + rel)
                info = tarfile.TarInfo(rel)
                info.size, info.mtime, info.mode = len(data), 0, 0o644
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def load(results):
    """{relative path: bytes} from the checked-in archive, after checking its sha256 and members.

    Raises ValueError on any mismatch. Only the pinned receipts are accepted: every member must be
    a regular file listed in receipts.sha256 with that hash, and every listed file must be present.
    """
    with open(os.path.join(results, ARCHIVE), "rb") as f:
        blob = f.read()
    with open(os.path.join(results, ARCHIVE_SHA)) as f:
        pinned = f.read().split()[0]
    if sha256(blob) != pinned:
        raise ValueError("%s does not match %s" % (ARCHIVE, ARCHIVE_SHA))
    want = {rel: h for h, rel in listing(results)}
    got = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for member in tar.getmembers():
            if not member.isreg() or not safe_name(member.name) or member.name not in want or member.name in got:
                raise ValueError("unexpected archive member: " + member.name)
            data = tar.extractfile(member).read()
            if sha256(data) != want[member.name]:
                raise ValueError("receipt changed in archive: " + member.name)
            got[member.name] = data
    missing = sorted(set(want) - set(got))
    if missing:
        raise ValueError("receipts missing from archive: " + ", ".join(missing))
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--cache", default=DEFAULT_CACHE)
    a = ap.parse_args()
    try:
        blob = build(a.results, a.cache)
    except (OSError, ValueError) as e:
        sys.exit("refusing: %s" % e)
    path = os.path.join(a.results, ARCHIVE)
    if os.path.lexists(path):
        with open(path, "rb") as f:
            if f.read() != blob:
                sys.exit("refusing: %s exists with different bytes; never overwritten" % path)
    else:
        tmp = "%s.tmp-%d" % (path, os.getpid())
        with open(tmp, "xb") as f:
            f.write(blob)
        os.replace(tmp, path)
    with open(os.path.join(a.results, ARCHIVE_SHA), "w") as f:
        f.write("%s  %s\n" % (sha256(blob), ARCHIVE))
    load(a.results)  # read back exactly as verify.py will
    print("%s: %d receipts, %d bytes, sha256 %s" % (path, len(listing(a.results)), len(blob), sha256(blob)))


if __name__ == "__main__":
    main()
