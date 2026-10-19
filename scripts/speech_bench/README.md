# Tokens speech bench

Our own accuracy and speed numbers for the speech models in Settings › Models, measured on our
Mac with the exact worker binaries the app ships. Every number in `results/` traces to a receipt;
anything we did not measure says "not measured".

## What is measured

| Measure | Definition |
|---|---|
| WER clean / other / combined | Corpus word error rate: (substitutions + deletions + insertions) / reference words, summed over clips, after Whisper's `EnglishTextNormalizer` on both sides (the Open ASR Leaderboard's normalizer). From timed request 1 of each clip. |
| Decode latency median / p90 | Per timed request: end of writing the ORK1 request frame to the newline of the result line. This is the worker's decode time for complete audio; it excludes key release, capture, the app's queueing and paste. The timed requests repeat a clip the worker has just decoded (see Limits). p90 uses linear interpolation between ranks. |
| 10-second talk | Median decode latency over timed requests on clips 8.0–12.0 s long. The Models tab shows it as "Speed". |
| Accuracy (Models tab) | 100 − combined WER. Not the share of reference words recognized: insertions count as errors too (see Limits). |
| Speed × realtime | Total timed audio seconds / total timed decode seconds. |
| Cold load | New worker process: spawn to the `ready` line. 3 runs per model; median reported, all three kept. The OS file cache is not purged (that needs admin), so this is a warm-disk cold start. |
| First request after ready | Latency of the very first request in the warm process (untimed warm-up of clip 1). Shown separately; it is not in the latency stats. |
| Peak RSS | `ru_maxrss` from `wait4()` on the worker process (bytes on macOS). Metal buffers in unified memory may not all be counted in RSS. |
| Determinism | Each clip is decoded 4 times (1 warm-up + 3 timed); the number of clips whose 4 texts differ is reported. |

Not measured: **Apple** (SFSpeechRecognizer) — it needs Speech Recognition permission in an app
context, and this bench runs no app and asks for no permission.

## Runtime under test

Supply `--runtime-root /absolute/path/to/Reviewed.app/Contents/Resources` explicitly.
That directory must contain `Orukeet/orukeet-worker`, `Orukeet/lib/` and
`Transcribe/transcribe-worker`. The benchmark launches them as child
processes exactly as `Sources/Tokens/Speech/OrukeetWorker.swift` runs them:

```
<worker> --model /abs/model.gguf --gpu 0
GGML_BACKEND_DL_PATH=<Orukeet/lib> (orukeet-worker) | <Transcribe> (transcribe-worker), OMP_NUM_THREADS=2
```

The `.app` is never launched. Nothing is written to `~/Library` or Tokens defaults. The weights
are the nine pinned files in `models.json` (copied from `SpeechModelCatalog.swift`);
`fetch.py` refuses any file whose sha256 or size differs from the pin and moves it aside as
`<file>.rejected-<UTC time>` (it never deletes a file). It refuses symlinked destinations,
`.part`/`.segNN` files and cache folders, runs one at a time per cache, and appends each
acquisition receipt to `fetch-receipts.jsonl` as soon as that file is checked.
`python3 scripts/speech_bench/test_fetch.py` proves all three without network.

## Preregistration

`prepare.py` wrote `manifest.json` before any model ran; its sha256 is in each results folder's
`manifest.sha256` and `summary.json`, and `bench.py` re-hashes every decoded clip against it.

- Data: LibriSpeech `test-clean` and `test-other` (Panayotov et al. 2015, CC BY 4.0,
  https://www.openslr.org/12/). Archives verified against OpenSLR's published md5; their sha256
  is in the manifest.
- Eligible: 16 kHz mono, at most 480 000 samples (30 s, the worker maximum), with a transcript.
- 100 clips per set, stratified by duration (seconds, lower bound inclusive):
  `[0,3):10  [3,8):30  [8,12):25  [12,15):15  [15,20):10  [20,30]:10`.
  70 per set are 3–15 s (spoken-request length); 25 per set are 8–12 s ("10-second talk").
- Within a bin: order by `sha256("20261016:<set>:<utterance id>")` ascending, take the first N.
- Decoding: ffmpeg FLAC → float32 little-endian mono 16 kHz (`int16 / 32768`, no resampling);
  the decoded sample count must equal the FLAC STREAMINFO total.

Because the selection is stratified, the clip mix is not LibriSpeech's natural duration mix, so
our WER is not directly comparable to a full-test-set leaderboard figure.

## Procedure per model

One model at a time, nothing else from the bench running.

1. Verify the weights' sha256 against the pin.
2. Three cold loads (spawn → `ready` → close stdin).
3. One warm process. For each of the 200 clips in manifest order: one untimed warm-up request,
   then 3 timed requests. Every result line is validated (request id, sample count, `is_final`).
4. Close stdin; record `ru_maxrss` and exit status.

Raw receipts (every `ready` and `result` line verbatim, with its timing, the workers' stderr and
`env.json`) are written to `~/.cache/tether-speech-bench/raw/<run id>/`, and
`results/<run>/receipts.sha256` pins each file's sha256. `pack_receipts.py` then checks them in as
`results/<run>/raw-receipts.tar.gz` (each file re-checked against its pin; fixed owner and times,
so the same receipts give the same bytes) with the archive's own sha256 in
`raw-receipts.tar.gz.sha256`. `verify.py` reads the receipts from that archive in memory (nothing is
extracted); `--receipts cache` reads the cache copy instead.

A model that fails keeps its rows out of `per_clip.csv`; its receipt ends with a `failed` line
and is closed before it is hashed, its worker is always reaped, and every output file is written
whole (temp file, then rename). `summary.json` › `selection` records any `--models`, `--clips` or
`--dry-run`; `to_swift.py` refuses those runs, and any run whose models are not the whole
`models.json` catalogue or whose clips are not the whole manifest.

## Rerun

```
# 1. weights + archives (pinned hashes; mirrors are official OpenSLR mirrors)
python3 -I scripts/speech_bench/fetch.py --mirror https://openslr.elda.org/resources/12 \
    --mirror https://openslr.trmal.net/resources/12 --mirror https://www.openslr.org/resources/12
# 2. scoring venv (Python 3.9, pinned)
uv venv --python /usr/bin/python3 .venv-bench
VIRTUAL_ENV=.venv-bench uv pip install -r scripts/speech_bench/requirements.txt
# 3. clip set (refuses to overwrite an existing manifest.json)
python3 -I scripts/speech_bench/prepare.py
# 4. dry run: 2 clips, 1 model, output in the cache
.venv-bench/bin/python -I scripts/speech_bench/bench.py --runtime-root /absolute/path/to/Reviewed.app/Contents/Resources --dry-run
# 5. full run
.venv-bench/bin/python -I scripts/speech_bench/bench.py --runtime-root /absolute/path/to/Reviewed.app/Contents/Resources --out scripts/speech_bench/results/<date>-<mac>
# 6. check the raw receipts in beside the results
python3 -I scripts/speech_bench/pack_receipts.py scripts/speech_bench/results/<date>-<mac>
# 7. audit from receipts
.venv-bench/bin/python -I scripts/speech_bench/verify.py scripts/speech_bench/results/<date>-<mac>
# 8. write the numbers into the app (refuses dry, filtered or partial runs)
python3 scripts/speech_bench/to_swift.py scripts/speech_bench/results/<date>-<mac>/summary.json \
    --machine-name "MacBook Pro" --build <build>
```

Paths are relative to the repository; the cache defaults to `~/.cache/tether-speech-bench/`. Raw results can contain machine metadata: keep them private and publish only reviewed summaries.

## Files

| File | Purpose |
|---|---|
| `models.json` | Pinned weights (URL, sha256, bytes) and dataset archives (OpenSLR md5). |
| `fetch.py` | Downloads and verifies; `--local-copy` clones an identical local file instead. |
| `test_fetch.py` | No-network self-test of `fetch.py`'s safety rules. |
| `prepare.py` | Selection, decoding, `manifest.json`. |
| `bench.py` | Runner, timing, receipts, summary. |
| `score.py` | Normalizer + jiwer counts, cross-checked by an independent Levenshtein. |
| `verify.py` | Audit: re-hashes receipts, re-scores raw hypotheses, recomputes every WER and latency figure. |
| `pack_receipts.py` | Packs a run's pinned raw receipts into `results/<run>/raw-receipts.tar.gz`. |
| `to_swift.py` | Writes a complete run's numbers and run id into `Sources/TokensCore/Settings/SpeechBenchmarks.swift`. |
| `whisper_normalizer/` | openai/whisper `normalizers/` at tag v20250625 (`31243ba`), byte-for-byte, MIT (`LICENSE`). |
| `requirements.txt` | Pinned scoring dependencies. |
| `manifest.json` | The preregistered 200 clips with reference text and audio hashes. |
| `results/<run>/` | `summary.json`, `per_clip.csv`, `hypotheses.jsonl`, `manifest.sha256`, `receipts.sha256`, `raw-receipts.tar.gz` + `.sha256`. |

## Results: 2026-10-16, Apple M5 (`results/2026-10-16-m5/`)

Generated from `summary.json` (run `20261017T010320Z`, 27 min 20 s, manifest `896c7ad0…`).
Apple M5 (Mac17,2), 24 GB, macOS 26.6.2 (25G83), on AC power, build 81 workers
(`transcribe-worker` `19642ffb…`, `orukeet-worker` `90e94485…`). No thermal or performance
warning was recorded before or after any model.

| Model | WER clean % | WER other % | WER combined % | 10-s talk median s | Decode median / p90 s | Speed × realtime | Cold load s | Cold first result s | Peak RSS MB | Clips |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Orukeet | 1.08 | 2.80 | 1.97 | 0.056 | 0.056 / 0.103 | 163 | 0.06 | 0.27 | 843 | 200 |
| Parakeet v2 | 0.90 | 2.70 | 1.82 | 0.083 | 0.081 / 0.153 | 114 | 0.22 | 0.31 | 898 | 200 |
| Parakeet v3 | 1.19 | 2.98 | 2.11 | 0.100 | 0.096 / 0.185 | 95 | 0.24 | 0.34 | 958 | 200 |
| Canary 1B Flash | 0.93 | 3.22 | 2.11 | 0.153 | 0.150 / 0.292 | 62 | 0.41 | 0.58 | 1179 | 200 |
| Qwen3 ASR | 1.42 | 3.96 | 2.73 | 0.337 | 0.321 / 0.610 | 29 | 0.35 | 0.64 | 1529 | 200 |
| Moonshine Medium | 1.31 | 4.62 | 3.02 | 0.227 | 0.219 / 0.610 | 38 | 0.15 | 0.37 | 1066 | 200 |
| Whisper Turbo | 1.31 | 3.08 | 2.22 | 0.635 | 0.626 / 0.695 | 16 | 0.82 | 1.42 | 1127 | 200 |
| Whisper Small | 2.31 | 5.96 | 4.19 | 0.228 | 0.222 / 0.322 | 44 | 0.26 | 0.47 | 488 | 200 |
| Whisper Base | 3.73 | 8.34 | 6.11 | 0.095 | 0.093 / 0.139 | 106 | 0.14 | 0.23 | 253 | 200 |
| Apple | not measured | not measured | not measured | not measured | not measured | not measured | not measured | not measured | not measured | 0 |

Read the cold columns together: `orukeet-worker` sends `ready` before it has done any decoding
work, so its first request after `ready` takes about 0.2 s (0.06 s once warm), while `transcribe-worker` warms up on one
second of silence before `ready`. "Cold first result" (spawn to the first result on one 8–12 s
probe clip) compares the two fairly. Every model gave identical text on all four decodes of
every clip.

`verify.py results/2026-10-16-m5` re-scores every hypothesis from the raw receipts and recomputes
the WER and latency figures; it reports OK for this run, from the checked-in
`raw-receipts.tar.gz` (587 447 bytes, sha256 `4d010ca8…`, added 2026-10-17) and from the cache copy.

Harness provenance: this README, `bench.py` and `fetch.py` were edited after the run (2026-10-17
review fixes: normalizer hashing, selection record, failure receipts, fetch safety). The bytes that
ran are in commit `d924e7e` (`git show d924e7e:scripts/speech_bench/bench.py`), and `bench.py`,
`fetch.py`, `prepare.py`, `score.py`, `models.json` and `requirements.txt` there match their sha256
in `summary.json` › `environment.harness_files_sha256`. That run predates hashing the vendored
`whisper_normalizer/` files; they are unchanged since `d924e7e`, and `verify.py` re-scoring all
1,800 clip results with them reproduces every count. Runs from now on record their hashes, and
`verify.py` checks them.

## Deviations from the written plan

- LibriSpeech archives were fetched as parallel byte ranges from official OpenSLR mirrors
  (openslr.elda.org, openslr.trmal.net, www.openslr.org), because openslr.org alone served about
  130 KB/s. Both archives matched OpenSLR's published md5 (`md5sum.txt`).
- Orukeet and Whisper Base weights were cloned (APFS copy-on-write) from identical local copies
  after their sha256 matched the pin, instead of being downloaded again. The disk was 99% full.
- The normalizer files are vendored unchanged, with MIT `LICENSE` beside them, rather than with
  a licence header pasted into each file (byte-identical files are easier to audit).
- Added beyond the plan: "cold first result", "first request after ready", speed × realtime, and
  a determinism count.

## Limits

- **Read audiobook speech is not conversational talk.** LibriSpeech is people reading books aloud
  in quiet rooms. Dictation to a computer has disfluencies, names, code words and room noise, so
  real-use WER will be higher, and the ranking between models may differ.
- **One Mac.** All numbers come from one Apple M5 (see `summary.json` › `environment`). Speed on
  other chips, memory sizes or thermal states will differ.
- **200 clips.** Small differences in WER (well under a point) between models are within noise
  for a sample this size.
- Decode latency covers recognition of an already-captured clip. It excludes audio capture,
  endpointing, the app's own queueing and pasting.
- **Timed requests repeat audio the worker has just decoded.** Each clip gets one untimed warm-up
  decode, then 3 timed decodes of the same audio, and Speed is the median of those repeats. In
  real use every talk is new audio, and a first decode can be slower. The first decode of each
  8–12 s clip is in the receipts; `verify.py` prints its median beside the shipped one. For 8 of
  the 9 models the two agree within 3.4%; Moonshine Medium's first decodes are about 9% slower
  (0.247 s against the shipped 0.227 s). `summary.json` › `first_request_after_ready` keeps the
  very first request of each warm process apart as well (for Orukeet it includes lazy loading).
- **Accuracy is 100 − WER, so inserted words count against it.** WER is (S + D + I) / N, so the
  Accuracy column is lower than the share of reference words recognized, (N − S − D) / N, by the
  insertion rate: Whisper Small shows 95.8% although it recognized 96.6% of reference words
  (44 inserted words); for the other models the gap is 0.2–0.8 points. The ranking is the same
  either way. It is the usual convention, and published comparisons use it too.
- The OS file cache was not purged before cold loads, and other agents' processes may have been
  running on the machine (load average is recorded before and after each model).
- English only. Several models are multilingual; we did not test other languages.
