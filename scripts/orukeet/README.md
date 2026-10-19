# Native Orukeet assets

This optional package contains a retained offline recognizer, the unchanged Orukeet
v0.1.0 Q8 model and the official macOS arm64 Metal SDK 0.1.1. No Python runtime,
network client, microphone capture or model downloader is shipped. Python is used
only by local build/package tooling. The normal package does not require these assets.

## Stage from existing local inputs

```sh
python3 scripts/orukeet/stage_assets.py \
  --sdk /absolute/path/nemo-speech-orukeet-0.1.1-macos-arm64-metal \
  --model /absolute/path/orukeet-v0.1.0-q8.gguf \
  --output /absolute/path/fresh-orukeet-assets
```

The output must be fresh. The script validates the SDK header/build manifest and
every SDK library, plus the 714456704-byte model SHA256
`93ce19c6d8244acbfea980eeaf970531d4f216171578ef8e041dcc2d070a45bd`.
It compiles C++17 with strict warnings, arm64 and macOS14 minimum, then checks the
complete transitive linkage and relative rpaths without executing the worker.
Failed staging leaves an incomplete directory for inspection; it cannot pass packaging.
It performs no downloads and never loads the model.

Pass both `--enable-orukeet --orukeet-assets /absolute/path/fresh-orukeet-assets`
to `scripts/package_app.py` in addition to the existing mode/signing/resource args.
Omitting both preserves normal packaging; supplying only one is an error. SDK
libraries must retain their original input hashes. After copying, the packager
signs each library in dependency order, then the worker, verifies each signature,
updates the final file hashes, then signs/verifies the outer app. Its receipt
records native behavior as unproven. Reusing signed bundle assets as pristine
stage input is intentionally refused.

The package receipt also pins the original staged directory and its pre-sign
manifest SHA256. Retain that directory unchanged until installation: the installer
checks its official input pins and every `orukeet-assets/` source row, then checks
the bundled signed manifest separately against the receipt and app signature.
Signed binary hashes legitimately differ from pristine SDK hashes; neither set
replaces the other. Receipts missing this stage binding are refused and require
repackaging, with no installer override.

Bundle contract:

```text
Contents/Resources/Orukeet/
  orukeet-worker                 # @executable_path/lib rpath
  orukeet-v0.1.0-q8.gguf
  lib/*.dylib                    # complete pinned SDK; regular files, no symlinks
  licenses/orukeet/*
  licenses/nemo-speech/*         # includes transitive SDK notices
  sdk-build.json
  asset-manifest.json
```

`TokensOrukeetEnabled=true` is set in Info.plist only for an enabled bundle.
The runtime resolver must use this bundle directory, verify the manifest and model,
and set `GGML_BACKEND_DL_PATH` to its `lib` subdirectory. It must not inherit an
arbitrary executable/model path from user defaults. The manifest `files` values
are final signed SHA256 hashes, while `sdk-build.json` preserves pristine upstream
input hashes. Worker/model readiness is separate from the user's selected engine:
a missing/failed worker must remain a visible unavailable/fallback state.

## Worker protocol ORK1

Invoke the explicit worker path with `--model ABSOLUTE_MODEL_PATH --gpu 0` for
Metal (`--gpu -1` requests CPU). The retained recognizer initializes once, then
prints one JSON `ready` line (`protocol: "ORK1"`, `mode: "offline_retained"`).
SDK stdout is redirected to stderr so stdout contains protocol JSON only.

Each stdin request is a 20-byte little-endian header followed by audio:

| Field | Type | Contract |
|---|---|---|
| magic | 4 bytes | ASCII `ORK1` |
| request_id | UInt64 LE | nonzero, strictly increasing |
| sample_rate | UInt32 LE | 8000–96000 |
| sample_count | UInt32 LE | 1–30 seconds at sample_rate |
| audio | sample_count Float32 LE | finite mono samples |

Each result is one JSON line with decimal-string `request_id`, `sample_count`,
`sample_rate`, actual SDK `text`, and `words: [{text,start_ms,end_ms}]`.
Timestamps are the SDK's integer millisecond offsets into that request's audio.
`is_final:true`/`mode:"offline"` means that bounded request completed, not that a
microphone utterance or destination delivery completed. Prefix requests are
independent repeated offline recognition on one retained model; this is not the
unsupported SDK native streaming API. Native automatic punctuation and verbatim
transcripts are enabled; no separate language model rewrites the result.

One request may run while one further complete frame queues. Normally await the
matching result before submitting the next request. The host must bound each
child's startup/request time and reject stale generations after cancellation.
The SDK's synchronous recognize call cannot be interrupted internally. EOF between
frames stops cleanly; malformed, nonfinite, oversized and truncated input fails
with an error and nonzero exit. Logs must stay local and must not store real audio
or real dictated words without user authorization.

## Attribution

Orukeet is an Oruk AI adaptation of NVIDIA Parakeet TDT 0.6B v3. These exact Q8
weights are copied unchanged; their license is CC BY-SA4.0. Preserve
`licenses/orukeet/NOTICE.md` and `LICENSE-WEIGHTS`, including NVIDIA attribution
and the upstream ancestry/scope information. Orukeet integration code is MIT;
SDK components retain their included Apache2/MIT and other third-party notices.
This source adds a native process/protocol adapter and packaging, not changes to
the model. The SDK's source commits and patches are recorded in `sdk-build.json`.

Primary provenance: <https://github.com/Oruk-AI/orukeet>, SDK tag `v0.1.1`, model
revision `555136b50265a132d4cea0d35560c26fc4f657ab`. The original notices are copied
verbatim. Models, SDK binaries, generated stages and real-audio receipts must not
be committed to the repository.
