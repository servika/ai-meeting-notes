#!/usr/bin/env bash
# Build a self-contained, native whisper.cpp `whisper-cli` to bundle in the app.
#
# We build statically (-DBUILD_SHARED_LIBS=OFF) so the result is a single binary
# with no libwhisper/libggml dylib dependencies - only system frameworks
# (Metal, Accelerate, ...) that are always present. The Metal shader is embedded.
# The binary is cached at vendor/whisper-cli so app builds don't recompile it.
#
# Usage: scripts/build-whisper.sh [--force]
set -euo pipefail

# Pinned whisper.cpp version (bump deliberately).
WHISPER_REF="v1.8.6"
# Must match the app's minimum (Package.swift `.macOS(...)` / LSMinimumSystemVersion).
DEPLOYMENT_TARGET="14.4"
REPO="https://github.com/ggml-org/whisper.cpp.git"

cd "$(dirname "$0")/.."          # packages/meeting-engine
ROOT="$(pwd)"
SRC="$ROOT/.build/whisper-src"
BUILD="$ROOT/.build/whisper-build"
OUT="$ROOT/vendor/whisper-cli"
VAD_OUT="$ROOT/vendor/ggml-silero-v5.1.2.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"

# Silero VAD model (~0.9 MB) - bundled so transcription can skip non-speech and
# avoid hallucinations on silence. Fetched independently of the whisper-cli cache.
if [[ ! -s "$VAD_OUT" ]]; then
  echo "Downloading Silero VAD model..."
  mkdir -p "$(dirname "$VAD_OUT")"
  curl -fsSL -o "$VAD_OUT" "$VAD_URL"
fi

# A binary whose `minos` is newer than the app's minimum launches fine here but
# dies at dyld time on an older Mac (see the deployment-target note below), so
# check it rather than trust the cache.
check_minos() {
  local got
  got="$(otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  if [[ "$got" != "$DEPLOYMENT_TARGET" ]]; then
    echo "ERROR: $1 targets macOS ${got:-?}, expected ${DEPLOYMENT_TARGET}." >&2
    echo "       It would crash on macOS < ${got:-?} with a dyld 'Symbol not found' error." >&2
    return 1
  fi
  echo "  minos: $got (matches the app minimum)"
}

if [[ "${1:-}" != "--force" && -x "$OUT" ]]; then
  echo "whisper-cli already built: $OUT ($(file -b "$OUT" | cut -d, -f1,2))"
  if check_minos "$OUT"; then
    echo "  (use --force to rebuild)"
    exit 0
  fi
  echo "  cached binary is stale - rebuilding..." >&2
fi

# Fetch source at the pinned ref (shallow, cached).
if [[ ! -d "$SRC/.git" ]]; then
  echo "Cloning whisper.cpp ${WHISPER_REF}..."
  rm -rf "$SRC"
  git clone --depth 1 --branch "$WHISPER_REF" "$REPO" "$SRC"
else
  echo "Reusing whisper.cpp source at $SRC"
  git -C "$SRC" fetch --depth 1 origin tag "$WHISPER_REF" >/dev/null 2>&1 || true
  git -C "$SRC" checkout -q "$WHISPER_REF" 2>/dev/null || true
fi

# Configure + build only the whisper-cli target, statically, native arch.
#
# CMAKE_OSX_DEPLOYMENT_TARGET must match the app's minimum (Package.swift
# `.macOS("14.4")` / LSMinimumSystemVersion). Without it cmake stamps the
# builder's own OS as `minos`, and the linker then *strongly* binds Metal
# classes newer than 14.4 (e.g. MTLResidencySetDescriptor, macOS 15+). The
# binary still launches on an older Mac and dies at dyld time with
# "Symbol not found: _OBJC_CLASS_$_MTLResidencySetDescriptor" (exit 6).
# With the target set, those classes are weak-linked and ggml's existing
# `if (@available(macOS 15.0, ...))` guards take the fallback path.
ARCH="$(uname -m)"
echo "Building whisper-cli (static, ${ARCH}, macOS ${DEPLOYMENT_TARGET}+)..."
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  >/dev/null
cmake --build "$BUILD" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null

# Locate the built binary (cmake puts it in build/bin).
BIN="$(find "$BUILD" -name whisper-cli -type f -perm -111 | head -1)"
if [[ -z "$BIN" ]]; then echo "ERROR: whisper-cli not produced"; exit 1; fi

mkdir -p "$(dirname "$OUT")"
cp "$BIN" "$OUT"
chmod +x "$OUT"

echo "built: $OUT"
file -b "$OUT" | sed 's/^/  /'
check_minos "$OUT"
echo "  dylib deps (should be system-only):"
otool -L "$OUT" | tail -n +2 | grep -v '/usr/lib/\|/System/' | sed 's/^/  ⚠️  /' || echo "    (none - fully self-contained)"