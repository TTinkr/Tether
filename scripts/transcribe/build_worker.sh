#!/bin/zsh
# usage: build_worker.sh <transcribe.cpp checkout at TRANSCRIBE_COMMIT> <out dir> [cmake]
# Builds transcribe.cpp (static, Metal + CPU, macOS 14) and links transcribe-worker against it.
# Pinned engine: handy-computer/transcribe.cpp (MIT) at the commit below; the checkout must match.
set -euo pipefail
TRANSCRIBE_COMMIT=e0d5e6174bd5cceecfed4f1bb04d160bddb59f8f
SRC=${1:?transcribe.cpp checkout}; OUT=${2:?out dir}; CMAKE=${3:-cmake}
HERE=${0:A:h}
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$TRANSCRIBE_COMMIT" ]] || { echo "transcribe.cpp is not at $TRANSCRIBE_COMMIT" >&2; exit 65; }
[[ -z "$(git -C "$SRC" status --porcelain --untracked-files=all)" ]] || { echo "transcribe.cpp checkout must be clean, including untracked files" >&2; exit 65; }
BUILD="$OUT/build"
# Strip build-machine paths from compiled __FILE__ strings as well as debug data.
# Keep diagnostics useful with stable source-relative prefixes.
PREFIX_MAPS="-ffile-prefix-map=${(q)SRC}=transcribe.cpp -ffile-prefix-map=${(q)HERE}=scripts/transcribe"
"$CMAKE" -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DTRANSCRIBE_BUILD_TESTS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 "-DCMAKE_C_FLAGS=$PREFIX_MAPS" "-DCMAKE_CXX_FLAGS=$PREFIX_MAPS"
"$CMAKE" --build "$BUILD" -j 4
clang++ "-ffile-prefix-map=$SRC=transcribe.cpp" "-ffile-prefix-map=$HERE=scripts/transcribe" -std=c++17 -O2 -mmacosx-version-min=14.0 -Wall -Wextra -I"$SRC/include" "$HERE/transcribe_worker.cpp" \
  "$BUILD/src/libtranscribe.a" "$BUILD/ggml/src/libggml.a" "$BUILD/ggml/src/ggml-metal/libggml-metal.a" \
  "$BUILD/ggml/src/libggml-cpu.a" "$BUILD/ggml/src/libggml-base.a" \
  -framework Accelerate -framework Foundation -framework Metal -framework MetalKit -o "$OUT/transcribe-worker"
cp "$SRC/LICENSE" "$OUT/LICENSE-transcribe.cpp"
# The worker statically links vendored components. Preserve their own copyright
# and permission notices along with the engine's MIT license.
cp "$SRC/THIRD-PARTY-LICENSES.md" "$OUT/THIRD-PARTY-LICENSES-transcribe.cpp.md"
shasum -a 256 "$OUT/transcribe-worker"
