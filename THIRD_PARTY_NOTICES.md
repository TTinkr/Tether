# Third-party components

The repository LICENSE covers original app source, not every external component or model.

| Component | Source/pin | License location |
|---|---|---|
| Sparkle | `Package.resolved` (2.9.6) | Upstream Sparkle license and framework notices |
| transcribe.cpp | `scripts/transcribe/build_worker.sh` | Worker stage copies upstream MIT LICENSE and THIRD-PARTY-LICENSES.md, including ggml, miniz and Silero VAD notices |
| Orukeet integration and native SDK | `scripts/orukeet/sdk-build.json` | `scripts/orukeet/licenses/` |
| Orukeet model weights | Optional external download | `scripts/orukeet/licenses/orukeet/LICENSE-WEIGHTS` (CC BY-SA 4.0) |
| Whisper text normalizer | `scripts/speech_bench/whisper_normalizer` | Adjacent MIT LICENSE |
| Other downloadable speech models | `Sources/TokensCore/Settings/SpeechModelCatalog.swift` | Model-origin licenses; inspect before redistribution |

Preserve the upstream copyright and notice files when bundling workers or SDKs. Apple frameworks are supplied by macOS/Xcode, not relicensed by this repository. Brand imagery includes generated artwork with embedded provenance; see asset notes. The source license does not grant trademark rights.

## Downloadable model origins

No model weights are included in this source snapshot. The app's catalog pins the downloaded file's revision, byte count and SHA-256. These checks establish file identity, not rights to relicense it. If you redistribute weights, retain the model publisher's full license and attribution, including the converter's notices and any applicable modification or ShareAlike terms.

| Model | Original publisher and stated weight license | Downloaded format |
|---|---|---|
| Orukeet | [Oruk AI](https://huggingface.co/oruk/orukeet), CC BY-SA 4.0; adapted from NVIDIA Parakeet v3 | Oruk AI Q8 GGUF; local license and ancestry notice in `scripts/orukeet/licenses/orukeet/` |
| Parakeet v2 | [NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), CC BY 4.0 | handy-computer Q8 GGUF |
| Parakeet v3 | [NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), CC BY 4.0 | handy-computer Q8 GGUF |
| Canary 1B Flash | [NVIDIA](https://huggingface.co/nvidia/canary-1b-flash), CC BY 4.0 | handy-computer Q8 GGUF |
| Qwen3 ASR 0.6B | [Qwen](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), Apache 2.0 | handy-computer Q8 GGUF |
| Moonshine Streaming Medium | [Useful Sensors / Moonshine AI](https://huggingface.co/moonshine-ai/moonshine-streaming-medium), MIT | handy-computer Q8 GGUF |
| Whisper Turbo, Small.en and Base.en | [OpenAI Whisper](https://github.com/openai/whisper), MIT | handy-computer Q8 GGUF |

The handy-computer conversions are from [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp); exact artifact URLs and hashes are in `Sources/TokensCore/Settings/SpeechModelCatalog.swift`. Model publishers retain responsibility for their training-data provenance; this repository makes no independent claim to have cleared every upstream dataset.

The benchmark normalizer is copied from [OpenAI Whisper v20250625](https://github.com/openai/whisper/tree/v20250625/whisper/normalizers), with its MIT license. Python packages in `scripts/speech_bench/requirements.txt` and `scripts/requirements-dmg.txt` are local benchmark/packaging tools, not app runtime components; preserve their installed distributions' notices if redistributing those tools.
