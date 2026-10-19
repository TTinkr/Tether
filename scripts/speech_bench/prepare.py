#!/usr/bin/env python3
"""Preregister the clip set: select LibriSpeech utterances, decode them, write manifest.json.

Run this once, before any model runs. It never touches a model or worker.

Selection rule (fixed in advance, documented in README.md):
  - Sets: LibriSpeech test-clean and test-other (OpenSLR resource 12, CC BY 4.0).
  - Eligible: every utterance whose FLAC STREAMINFO says 16 kHz mono and at most 480000 samples
    (30.0 s, the worker's maximum).
  - Duration bins (seconds, lower bound inclusive) and clips per set:
      [0,3):10  [3,8):30  [8,12):25  [12,15):15  [15,20):10  [20,30]:10   -> 100 per set
    so 70 of 100 clips per set fall in 3-15 s, and 25 per set in the 8-12 s "10-second talk" bin.
  - Within a bin, utterances are ordered by sha256("<seed>:<set>:<utterance id>") ascending and the
    first N are taken. This is reproducible in any language and needs no RNG implementation.
  - Seed: 20261016.
Decoding: ffmpeg FLAC -> 32-bit float little-endian, mono, 16 kHz (LibriSpeech is already 16 kHz
mono, so this is a lossless sample-format change: int16 / 32768). The decoded sample count must
equal the FLAC STREAMINFO total.

Usage: python3 -I prepare.py [--cache DIR] [--out manifest.json] [--seed 20261016]
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CACHE = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "cache", "speech-bench"))
SETS = ["test-clean", "test-other"]
BINS = [(0.0, 3.0, 10), (3.0, 8.0, 30), (8.0, 12.0, 25), (12.0, 15.0, 15), (15.0, 20.0, 10), (20.0, 30.0, 10)]
MAX_SAMPLES = 480000
FFMPEG = "/opt/homebrew/bin/ffmpeg"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def streaminfo(head):
    """Parse the FLAC STREAMINFO block from the first 42 bytes of a .flac file."""
    if head[:4] != b"fLaC" or (head[4] & 0x7F) != 0:
        raise ValueError("not a FLAC file starting with STREAMINFO")
    si = head[8:42]
    rate = (si[10] << 12) | (si[11] << 4) | (si[12] >> 4)
    channels = ((si[12] >> 1) & 0x07) + 1
    bits = (((si[12] & 0x01) << 4) | (si[13] >> 4)) + 1
    total = ((si[13] & 0x0F) << 32) | (si[14] << 24) | (si[15] << 16) | (si[16] << 8) | si[17]
    return rate, channels, bits, total


def bin_of(seconds):
    for lo, hi, _ in BINS:
        if lo <= seconds < hi or (hi == BINS[-1][1] and lo <= seconds <= hi):
            return "%g-%g" % (lo, hi)
    return None


def scan(archive):
    """Pass 1: transcripts plus each FLAC's STREAMINFO, streaming through the tarball."""
    texts, info = {}, {}
    with tarfile.open(archive, "r|gz") as tar:
        for m in tar:
            if not m.isfile():
                continue
            if m.name.endswith(".trans.txt"):
                for line in tar.extractfile(m).read().decode("utf-8").splitlines():
                    if line.strip():
                        uid, text = line.split(" ", 1)
                        texts[uid] = text.strip()
            elif m.name.endswith(".flac"):
                uid = os.path.basename(m.name)[:-5]
                info[uid] = (m.name, streaminfo(tar.extractfile(m).read(42)))
    return texts, info


def extract(archive, wanted, dest_dir):
    """Pass 2: write only the selected FLAC members (by exact member name) to dest_dir."""
    got = {}
    with tarfile.open(archive, "r|gz") as tar:
        for m in tar:
            if m.isfile() and m.name in wanted:
                path = os.path.join(dest_dir, os.path.basename(m.name))
                with open(path, "wb") as f:
                    f.write(tar.extractfile(m).read())
                got[m.name] = path
    missing = set(wanted) - set(got)
    if missing:
        raise RuntimeError("members not found: %s" % sorted(missing)[:3])
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=DEFAULT_CACHE)
    ap.add_argument("--out", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument("--seed", type=int, default=20261016)
    a = ap.parse_args()
    if os.path.exists(a.out):
        sys.exit("refusing to overwrite preregistered manifest %s" % a.out)
    sums = json.load(open(os.path.join(a.cache, "downloads", "librispeech", "checksums.json")))
    ffv = subprocess.run([FFMPEG, "-version"], capture_output=True, text=True, check=True).stdout.splitlines()[0]
    clips, datasets = [], {}
    for set_name in SETS:
        archive = os.path.join(a.cache, "downloads", "librispeech", set_name + ".tar.gz")
        if sha256_file(archive) != sums[set_name + ".tar.gz"]["sha256"]:
            sys.exit("archive hash changed since fetch: " + archive)
        texts, info = scan(archive)
        eligible, available = {}, {}
        for uid, (member, (rate, ch, bits, total)) in info.items():
            if rate != 16000 or ch != 1 or total <= 0 or total > MAX_SAMPLES or uid not in texts:
                continue
            b = bin_of(total / 16000.0)
            if b:
                eligible.setdefault(b, []).append(uid)
        chosen = []
        for lo, hi, quota in BINS:
            b = "%g-%g" % (lo, hi)
            pool = sorted(eligible.get(b, []), key=lambda u: hashlib.sha256(("%d:%s:%s" % (a.seed, set_name, u)).encode()).hexdigest())
            available[b] = len(pool)
            if len(pool) < quota:
                sys.exit("bin %s in %s has %d < %d" % (b, set_name, len(pool), quota))
            chosen += [(b, u) for u in pool[:quota]]
        datasets[set_name] = {
            "archive": os.path.basename(archive), "archive_sha256": sums[set_name + ".tar.gz"]["sha256"],
            "archive_md5": sums[set_name + ".tar.gz"]["md5"], "utterances_total": len(info),
            "eligible_total": sum(len(v) for v in eligible.values()), "eligible_per_bin": available}
        flac_dir = os.path.join(a.cache, "audio", "flac", set_name)
        f32_dir = os.path.join(a.cache, "audio", "f32le", set_name)
        os.makedirs(flac_dir, exist_ok=True)
        os.makedirs(f32_dir, exist_ok=True)
        paths = extract(archive, {info[u][0] for _, u in chosen}, flac_dir)
        for b, uid in sorted(chosen, key=lambda x: x[1]):
            member, (_, _, _, total) = info[uid]
            flac = paths[member]
            raw = os.path.join(f32_dir, uid + ".f32")
            subprocess.run([FFMPEG, "-nostdin", "-v", "error", "-y", "-i", flac, "-f", "f32le", "-acodec", "pcm_f32le",
                            "-ac", "1", "-ar", "16000", raw], check=True)
            n = os.path.getsize(raw) // 4
            if n != total:
                sys.exit("decoded %s has %d samples, STREAMINFO says %d" % (uid, n, total))
            clips.append({"id": uid, "set": set_name, "bin": b, "samples": total, "duration_s": round(total / 16000.0, 4),
                          "ref_text": texts[uid], "flac_member": member, "flac_sha256": sha256_file(flac),
                          "audio_f32le_sha256": sha256_file(raw), "audio_path": os.path.relpath(raw, a.cache)})
    manifest = {
        "schema": "tinkr-speech-bench-manifest/1",
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "seed": a.seed,
        "selection_rule": ("Per set: eligible = 16 kHz mono, <= 480000 samples (30.0 s), has transcript. Bins "
                           "[lo,hi) seconds (last bin closed) with quotas %s. Within a bin, order by "
                           "sha256('<seed>:<set>:<utterance id>') hex ascending and take the first N."
                           % ", ".join("[%g,%g):%d" % b for b in BINS)),
        "bins": [{"lo": lo, "hi": hi, "per_set": q} for lo, hi, q in BINS],
        "datasets": datasets,
        "dataset_licence": "LibriSpeech ASR corpus, Panayotov et al. 2015, CC BY 4.0, https://www.openslr.org/12/",
        "decoder": {"tool": ffv, "command": "ffmpeg -nostdin -v error -y -i <flac> -f f32le -acodec pcm_f32le -ac 1 -ar 16000 <out.f32>"},
        "audio_root": "<cache>/ (relative audio_path)",
        "clips": clips,
    }
    with open(a.out, "w") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print("wrote %s: %d clips, sha256 %s" % (a.out, len(clips), sha256_file(a.out)))


if __name__ == "__main__":
    main()
