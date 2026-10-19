# Building and packaging

## Basic community app

Install Xcode 26+, its command-line tools and CMake on Apple Silicon. The package declares macOS 14 compatibility; engine availability varies by OS and hardware. From a clean clone:

```sh
swift test --jobs 2 --no-parallel
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/public_check.py
git clone https://github.com/handy-computer/transcribe.cpp.git .build/transcribe.cpp
git -C .build/transcribe.cpp checkout --detach e0d5e6174bd5cceecfed4f1bb04d160bddb59f8f
zsh scripts/transcribe/build_worker.sh "$PWD/.build/transcribe.cpp" "$PWD/.build/transcribe-stage"
python3 scripts/package_app.py --mode preview --version 0.3.60 --build-number 87 --resources-dir Resources/Release --transcribe-worker .build/transcribe-stage
```

Tests run serially because parallel asynchronous suites can time out on a busy Mac. The package command prints a receipt with the new `dist/.../Tokens Community.app` path. Open that app manually.

The community app is the Tokens dictation source, not the separate Tether workspace application. First run starts at the Accessibility step, with no Terms step or account. Permission requests follow its setup buttons: Microphone for recording, Accessibility for delivery, and Speech Recognition when Apple speech is selected. In compatible editors, finalized text can reveal after recording stops; this is not live text insertion during recording. See [Privacy](PRIVACY.md) for storage and network details.

The default preview mode builds `Tokens Community.app`, signs ad hoc, uses `com.tinkr.tokens.community.preview`, and does not install or configure automatic updates. Ad-hoc signatures are for local development; they are not notarized public binaries. Stable privacy permission grants and Gatekeeper behavior may differ from the official signed download. No project signing identity or private repository is needed.

Do not run the executable through `swift run` as a substitute for an app bundle when testing macOS permissions. Build-only and synthetic-test results do not establish live microphone/paste acceptance.

## Default Parakeet v3 runtime

Clone `https://github.com/handy-computer/transcribe.cpp` separately and check out `e0d5e6174bd5cceecfed4f1bb04d160bddb59f8f`, the exact `TRANSCRIBE_COMMIT` in `scripts/transcribe/build_worker.sh`. The checkout must be clean. Install CMake. Run:

```sh
zsh scripts/transcribe/build_worker.sh /absolute/path/to/transcribe.cpp /absolute/path/to/new-worker-stage
python3 scripts/package_app.py --mode preview --version 0.3.60 --build-number 87 --resources-dir Resources/Release --transcribe-worker /absolute/path/to/new-worker-stage
```

The worker build is arm64/macOS 14+, static Metal+CPU. Its package metadata makes Parakeet v3 the default for a fresh profile. First launch downloads the pinned 739,508,576-byte model from Hugging Face and verifies its SHA-256 before use. Capture waits for the selected local model; it never switches to Apple merely because weights are missing. Explicit saved selections survive updates. Apple can be selected on the Models page.

Runtime model downloads are pinned in `SpeechModelCatalog.swift`; model weights retain their own licenses (Parakeet v3: CC-BY-4.0). The transcribe runtime does not link the optional Orukeet SDK or SentencePiece library. This distinction addresses the known Orukeet advisory; it is not a claim that native model parsing is risk-free.

A deliberate minimal Apple-only build is available with `python3 scripts/package_app.py --mode preview --version 0.3.60 --build-number 87 --resources-dir Resources/Release --apple-only`. Omitting all backend flags is an error so an incomplete package cannot silently become Apple-first.

On private repositories, push CI also builds the pinned runtime and an ad-hoc preview ZIP as a seven-day Actions artifact. It downloads no speech weights, requests no app permissions and performs no microphone/paste test. Public-repository CI runs source checks without uploading an app.

## Optional Orukeet worker

**Distribution remains disabled for this optional backend.** The prior SDK pinned SentencePiece `0.2.0`, affected by [CVE-2026-1260](https://github.com/advisories/GHSA-38vq-g6vr-w8wf). This candidate pins a local SDK rebuild using SentencePiece `0.2.2`; its source and binary hashes are recorded in `scripts/orukeet/sdk-build.json`. Community distribution stays gated until that rebuilt SDK is independently qualified. The packager refuses `--mode distribution --enable-orukeet` before building or signing. The commands below are for local preview review; the default Parakeet community build does not include this SDK.

The native SDK file checksums/source pin are recorded in `scripts/orukeet/sdk-build.json`; model hash and release provenance are in `scripts/orukeet/assets.py` and its README. Supply the matching SDK and weights as separate local inputs:

```sh
python3 scripts/orukeet/stage_assets.py --sdk /absolute/path/to/sdk --model /absolute/path/to/model.gguf --output /absolute/path/to/new-orukeet-stage
python3 scripts/package_app.py --mode preview --version 0.3.60 --build-number 87 --resources-dir Resources/Release --enable-orukeet --orukeet-assets /absolute/path/to/new-orukeet-stage
```

The staging command validates pinned inputs and does not silently download them. Keep all native/runtime/model notices. No model file or private staging directory is included here.

## Maintainer distribution

For a first cleaned source export, scan the exact reviewed root commit with `python3 scripts/public_check.py --revision HEAD --snapshot-history`. The optional `PUBLIC_EXPORT_DENY_WORDS` environment variable supplies private identity terms; keep its values outside the source tree. Working-file scans do not establish the contents of a commit. Publish only the reviewed snapshot, without private branches, tags, build artifacts or agent logs; changing a private development repository's visibility exposes more than its current files. The scanner is a heuristic and does not inspect image pixels or establish license ownership.

Distribution mode requires your own Developer ID, notarization profile, HTTPS appcast and corresponding public update key. Private keys stay outside the repository. Do not reuse upstream appcast settings for a fork. The packager refuses missing/mismatched update settings; verification keys are public, signing secrets are not. Review app identities and resource branding before distributing a fork.

The Tokens/Tinkr names and marks identify the upstream project; the source license does not grant trademark rights. Forks should identify themselves clearly. The official website download and a community source build may use different versions or speech backends; a link to the website is not a claim of binary parity.

Only explicit developer mode enables mutating QA routes. A missing or unknown mode fails closed.
