# Benchmark scope

The model table retains historical measurements from 200 LibriSpeech recordings (100 test-clean and 100 test-other), run with build-81 speech workers on an M5 MacBook Pro with 24 GB memory. These are model transcription timings, not end-to-end microphone-to-editor latency or a competitor comparison. Current community builds have not independently reproduced those figures.

`benchmark-summary.json` is a redacted aggregate of the historical run. Machine-specific paths, private Git identifiers and raw receipt locations were omitted. Raw per-clip transcripts and environment archives are not distributed. Because those raw receipts are omitted, the aggregate is historical context, not independently verifiable raw proof. Use `scripts/speech_bench/README.md` and the pinned manifest to run a new benchmark in your own environment. Keep a complete local run receipt before changing generated Swift values.
