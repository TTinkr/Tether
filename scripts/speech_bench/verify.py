#!/usr/bin/env python3
"""Audit a results folder against its receipts, without rerunning any model.

Checks:
  1. manifest.sha256 matches manifest.json, and summary.json names the same hash.
  2. Every raw receipt listed in receipts.sha256 exists with that hash: read from the checked-in
     results/<run>/raw-receipts.tar.gz (its own sha256 checked first; nothing is extracted), or
     from <cache>/raw/<run id>/ with --receipts cache or when the run has no archive.
  3. Re-scores every hypothesis in the raw receipts (timed request 1) against the manifest
     reference and confirms per_clip.csv and summary.json WER counts.
  4. Recomputes median / p90 / 10-second-talk latency from the raw receipts' timings and
     confirms summary.json.
  5. When summary.json records the vendored normalizer's file hashes (runs after 2026-10-17),
     the files used to re-score match them.
Also prints, for information, each model's first-decode median on the 8-12 s clips (the untimed
warm-up request, new audio to the worker) beside the shipped repeat-decode median.
Usage: verify.py results/<run> [--cache DIR] [--receipts auto|archive|cache]
"""
import argparse
import csv
import hashlib
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score  # noqa: E402
import pack_receipts  # noqa: E402
from bench import percentile  # noqa: E402

DEFAULT_CACHE = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "cache", "speech-bench"))


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--cache", default=DEFAULT_CACHE)
    ap.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument("--receipts", choices=["auto", "archive", "cache"], default="auto")
    a = ap.parse_args()
    problems = []
    source = a.receipts
    if source == "auto":
        source = "archive" if os.path.exists(os.path.join(a.results, pack_receipts.ARCHIVE)) else "cache"
    archived = {}
    if source == "archive":
        try:
            archived = pack_receipts.load(a.results)
        except (OSError, ValueError) as e:
            problems.append("receipt archive: %s" % e)

    def receipt(rel):
        """Bytes of one pinned raw receipt, or None."""
        if source == "archive":
            return archived.get(rel)
        p = os.path.join(a.cache, rel)
        if not os.path.exists(p):
            return None
        with open(p, "rb") as f:
            return f.read()
    summary = json.load(open(os.path.join(a.results, "summary.json")))
    mhash = sha(a.manifest)
    listed = open(os.path.join(a.results, "manifest.sha256")).read().split()[0]
    if not (mhash == listed == summary["manifest_sha256"]):
        problems.append("manifest hash mismatch")
    for h, rel in pack_receipts.listing(a.results):
        data = receipt(rel)
        if data is None or hashlib.sha256(data).hexdigest() != h:
            problems.append("receipt missing or changed (%s): %s" % (source, rel))
    for name, want in summary["environment"].get("harness_files_sha256", {}).items():
        if name.startswith("whisper_normalizer/") and sha(os.path.join(HERE, name)) != want:
            problems.append("normalizer file differs from the run's: " + name)
    manifest = {c["id"]: c for c in json.load(open(a.manifest))["clips"]}
    rows = {(r["model"], r["clip_id"]): r for r in csv.DictReader(open(os.path.join(a.results, "per_clip.csv")))}
    checked = 0
    first_decode = []
    for m in summary["models"]:
        if m["status"] != "ok":
            continue
        tot = {"test-clean": [0, 0], "test-other": [0, 0]}
        timed, talk, warm_talk = [], [], []
        data = receipt(m["receipt_jsonl"])
        if data is None:
            problems.append("receipt missing: " + m["receipt_jsonl"])
            continue
        for line in data.decode("utf-8").splitlines():
            r = json.loads(line)
            if r["kind"] == "warmup" and 8.0 <= manifest[r["clip"]]["duration_s"] <= 12.0:
                warm_talk.append(r["seconds"])
            if r["kind"] != "timed":
                continue
            c = manifest[r["clip"]]
            timed.append(r["seconds"])
            if 8.0 <= c["duration_s"] <= 12.0:
                talk.append(r["seconds"])
            if r["rep"] != 1:
                continue
            sc = score.counts(c["ref_text"], json.loads(r["result_line"])["text"])
            row = rows[(m["id"], r["clip"])]
            if [int(row[k]) for k in ("ref_words", "sub", "del", "ins")] != [sc["n"], sc["s"], sc["d"], sc["i"]]:
                problems.append("per_clip mismatch %s %s" % (m["id"], r["clip"]))
            tot[c["set"]][0] += sc["s"] + sc["d"] + sc["i"]
            tot[c["set"]][1] += sc["n"]
            checked += 1
        for s in ("test-clean", "test-other"):
            want = round(100.0 * tot[s][0] / tot[s][1], 3)
            if want != m["wer"][s]["wer_percent"]:
                problems.append("WER mismatch %s %s: %s vs %s" % (m["id"], s, want, m["wer"][s]["wer_percent"]))
        comb = round(100.0 * (tot["test-clean"][0] + tot["test-other"][0]) / (tot["test-clean"][1] + tot["test-other"][1]), 3)
        if comb != m["wer"]["combined"]["wer_percent"]:
            problems.append("combined WER mismatch %s" % m["id"])
        for name, got, want in (("median", statistics.median(timed), m["latency_s"]["median"]),
                                ("p90", percentile(timed, 0.9), m["latency_s"]["p90"]),
                                ("talk10", statistics.median(talk), m["talk_10s_latency_s"]["median"])):
            if abs(got - want) > 1e-9:
                problems.append("%s mismatch %s" % (name, m["id"]))
        if warm_talk:
            first_decode.append((m["id"], statistics.median(warm_talk), m["talk_10s_latency_s"]["median"]))
    print("receipts read from the %s" % ("checked-in " + pack_receipts.ARCHIVE if source == "archive" else "cache " + a.cache))
    if first_decode:
        print("8-12 s clips, median s: first decode (untimed warm-up) vs repeat decode (shipped)")
        for mid, warm, shipped in first_decode:
            print("  %-28s %.4f  %.4f  x%.3f" % (mid, warm, shipped, warm / shipped))
    print("checked %d clip scores across %d models" % (checked, sum(1 for m in summary["models"] if m["status"] == "ok")))
    if problems:
        print("PROBLEMS:\n  " + "\n  ".join(problems))
        sys.exit(1)
    print("OK: manifest, receipts, per-clip counts, WER and latency stats all reproduce from receipts (%s)" % source)


if __name__ == "__main__":
    main()
