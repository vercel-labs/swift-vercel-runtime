#!/usr/bin/env bash
# Installs the swift.org toolchain and the Static Linux SDK in a Vercel build, so a Git deployment
# can run `swift package vercel` itself. It is the project's Install Command, which
# `swift package --disable-sandbox vercel init` sets in vercel.json (with the URL for its release):
#
#   Install Command: curl -fsSL https://raw.githubusercontent.com/vercel-labs/swift-vercel-runtime/0.6.1/scripts/vercel-install-swift.sh | bash
#   Build Command:   .vercel/bin/swift package --disable-sandbox vercel
#
# Vercel saves <repository root>/.vercel/cache after every build and restores it before the next
# one, so only a project's first build downloads Swift. Everything lives in
# .vercel/cache/swift/<version>: the toolchain (without the debugger, SourceKit and other tools a
# server build does not use), the SDK, and the package's .build for incremental builds. Other
# versions are deleted to stay under the build cache size limit.
#
# The build command runs .vercel/bin/swift, a wrapper this script writes into the project. It
# points `swift package vercel` at the cached SDK, and after a build saves .build to the cache
# as a tar file, unless it is larger than SWIFT_VERCEL_MAX_BUILD_CACHE_MB.
#
# Vercel stores the cache as SquashFS, which keeps file times to the second. SwiftPM compares
# them to the nanosecond and would rebuild everything, so .build is cached as a tar file (which
# keeps them exactly), and the toolchain and SDK get whole-second times when installed.
#
# Environment:
#   SWIFT_VERSION                    Swift release, like 6.4.0 or 6.4 (latest 6.4.x). Defaults to
#                                    the project's .swift-version file (which `vercel init` writes
#                                    with the local Swift version), then the latest release. Each
#                                    version has its own cache, so the first build after a change
#                                    (or after a new release, without a pin) is a cold one.
#   SWIFT_VERCEL_MAX_BUILD_CACHE_MB  Largest build directory to keep cached (default 2000).
set -euo pipefail

log() { echo "swift-vercel: $*"; }
die() {
  echo "swift-vercel: error: $*" >&2
  exit 1
}
seconds_since() { echo "$(($(date +%s) - $1))s"; }
# Gives every file the same whole-second modification time, so it survives the build cache: the
# compiler's module cache checks the toolchain's and SDK's files by modification time.
whole_second_times() { find "$1" -exec touch -h -d "@$(date +%s)" {} +; }

[ "$(uname -s)" = "Linux" ] || die "this installs Swift in Vercel's Linux build image. On your own machine, follow the README instead."
for tool in curl tar zstd gpg node; do
  command -v "$tool" >/dev/null || die "'$tool' is required"
done

case "$(uname -m)" in
  x86_64) ARCH_SUFFIX="" ;;
  aarch64) ARCH_SUFFIX="-aarch64" ;;
  *) die "unsupported build machine architecture $(uname -m)" ;;
esac

PROJECT_DIR="$PWD"
# Vercel only caches .vercel/cache at the repository root, which is above the project when the
# project has a Root Directory.
REPO_ROOT="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")"
CACHE_DIR="$REPO_ROOT/.vercel/cache/swift"

REQUESTED="${SWIFT_VERSION:-}"
if [ -z "$REQUESTED" ] && [ -f "$PROJECT_DIR/.swift-version" ]; then
  REQUESTED="$(tr -d '[:space:]' < "$PROJECT_DIR/.swift-version")"
fi

# Resolve the release, its Linux platform and the Static Linux SDK from swift.org's release list.
RELEASES="$(curl -fsSL --retry 3 https://www.swift.org/api/v1/install/releases.json)" ||
  die "could not download https://www.swift.org/api/v1/install/releases.json"
read -r VERSION TAG PLATFORM_DIR SDK_VERSION SDK_CHECKSUM < <(
  node -e '
    const [requested] = process.argv.slice(1);
    const releases = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const key = (name) => name.split(".").map(Number);
    const newer = (a, b) => {
      const [x, y] = [key(a.name), key(b.name)];
      for (let i = 0; i < Math.max(x.length, y.length); i++) {
        if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0);
      }
      return 0;
    };
    // Releases are named like 6.3 or 6.4.0, so compare numbers: 6.3.0 matches 6.3, and 6.4
    // matches every 6.4.x.
    const matches = (name) => key(requested).every((n, i) => n === (key(name)[i] ?? 0));
    const candidates = releases
      .filter((r) => !requested || matches(r.name))
      .filter((r) => r.platforms.some((p) => p.platform === "static-sdk"))
      .sort(newer);
    const release = candidates.at(-1);
    if (!release) process.exit(3);
    const sdk = release.platforms.find((p) => p.platform === "static-sdk");
    // Vercel builds on Amazon Linux 2023; older releases only have the compatible UBI 9 build.
    const platform = release.platforms.some((p) => p.name === "Amazon Linux 2023") ? "amazonlinux2023" : "ubi9";
    console.log([release.name, release.tag, platform, sdk.version ?? "0.0.1", sdk.checksum].join(" "));
  ' "$REQUESTED" <<< "$RELEASES"
) || die "no Swift release with a Static Linux SDK matches '${REQUESTED}'"

VERSION_DIR="$CACHE_DIR/$VERSION"
TOOLCHAIN="$VERSION_DIR/toolchain"
SDKS_PATH="$VERSION_DIR/swift-sdks"
PROJECT_KEY="$(realpath --relative-to="$REPO_ROOT" "$PROJECT_DIR" | tr '/' '_')"
[ "$PROJECT_KEY" = "." ] && PROJECT_KEY="root"
BUILD_ARCHIVE="$VERSION_DIR/build-$PROJECT_KEY.tar.zst"
SDK_ID="${TAG}_static-linux-${SDK_VERSION}"
DOWNLOADS="https://download.swift.org/$(echo "$TAG" | tr '[:upper:]' '[:lower:]')"

log "Swift $VERSION, cache in ${CACHE_DIR#"$REPO_ROOT"/}"

# Keep only this version in the cache.
if [ -d "$CACHE_DIR" ]; then
  for entry in "$CACHE_DIR"/*; do
    if [ -e "$entry" ] && [ "$entry" != "$VERSION_DIR" ]; then
      log "removing cached Swift $(basename "$entry")"
      rm -rf "$entry"
    fi
  done
fi
mkdir -p "$VERSION_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Toolchain
if [ -x "$TOOLCHAIN/usr/bin/swift" ]; then
  log "toolchain restored from the build cache"
else
  START=$(date +%s)
  FILE="$TAG-$PLATFORM_DIR$ARCH_SUFFIX.tar.gz"
  URL="$DOWNLOADS/$PLATFORM_DIR$ARCH_SUFFIX/$TAG/$FILE"
  log "downloading $URL"
  curl -fsSL --retry 3 -o "$TMP/$FILE" "$URL"
  curl -fsSL --retry 3 -o "$TMP/$FILE.sig" "$URL.sig"

  export GNUPGHOME="$TMP/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  # swift.org serves the keys gzip-encoded.
  curl -fsSL --retry 3 --compressed -o "$TMP/keys.asc" https://www.swift.org/keys/all-keys.asc
  gpg --batch --quiet --import "$TMP/keys.asc" > "$TMP/gpg.log" 2>&1 ||
    die "could not import swift.org's signing keys: $(cat "$TMP/gpg.log")"
  gpg --batch --verify "$TMP/$FILE.sig" "$TMP/$FILE" > "$TMP/gpg.log" 2>&1 ||
    die "the toolchain's signature does not verify against swift.org's keys: $(cat "$TMP/gpg.log")"
  log "verified the toolchain signature"

  rm -rf "$TOOLCHAIN.partial"
  mkdir -p "$TOOLCHAIN.partial"
  tar -xzf "$TMP/$FILE" -C "$TOOLCHAIN.partial" --strip-components=1
  rm -f "$TMP/$FILE"
  # Halves the toolchain (and the build cache): debugger, IDE support, docs, formatter, Wasm
  # runtime, Embedded Swift and the host's static stdlib are not used to build a server.
  usr="$TOOLCHAIN.partial/usr"
  rm -rf "$usr"/lib/swift/embedded "$usr"/lib/swift_static \
    "$usr"/lib/liblldb* "$usr"/bin/lldb* "$usr"/lib/python3* \
    "$usr"/lib/libsourcekitdInProc.so "$usr"/lib/libSwiftSourceKit*Plugin.so "$usr"/bin/sourcekit-lsp \
    "$usr"/bin/clangd "$usr"/bin/docc "$usr"/share/docc "$usr"/bin/swift-format "$usr"/bin/wasmkit
  whole_second_times "$TOOLCHAIN.partial"
  mv "$TOOLCHAIN.partial" "$TOOLCHAIN"
  log "installed the toolchain in $(seconds_since "$START")"
fi
"$TOOLCHAIN/usr/bin/swift" --version 2>&1 | head -1

# 2. Static Linux SDK
if "$TOOLCHAIN/usr/bin/swift" sdk list --swift-sdks-path "$SDKS_PATH" 2>/dev/null | grep -qx "$SDK_ID"; then
  log "Static Linux SDK restored from the build cache"
else
  START=$(date +%s)
  rm -rf "$SDKS_PATH"
  # Downloaded with curl: `swift sdk install <url>` can crash in URLSession on exit on Linux.
  BUNDLE="$TMP/${SDK_ID}.artifactbundle.tar.gz"
  log "downloading $DOWNLOADS/static-sdk/$TAG/${SDK_ID}.artifactbundle.tar.gz"
  curl -fsSL --retry 3 -o "$BUNDLE" "$DOWNLOADS/static-sdk/$TAG/${SDK_ID}.artifactbundle.tar.gz"
  echo "$SDK_CHECKSUM  $BUNDLE" | sha256sum --check --quiet ||
    die "the Static Linux SDK's checksum does not match swift.org's"
  "$TOOLCHAIN/usr/bin/swift" sdk install --swift-sdks-path "$SDKS_PATH" "$BUNDLE" > "$TMP/sdk.log" 2>&1 ||
    die "installing the Static Linux SDK failed: $(cat "$TMP/sdk.log")"
  rm -f "$BUNDLE"
  "$TOOLCHAIN/usr/bin/swift" sdk list --swift-sdks-path "$SDKS_PATH" | grep -qx "$SDK_ID" ||
    die "installing the Static Linux SDK $SDK_ID failed"
  whole_second_times "$SDKS_PATH"
  log "installed the Static Linux SDK in $(seconds_since "$START")"
fi

# 3. The package's .build from the previous build: resolved dependencies, the compiled plugin and
# (in .build/vercel) the plugin's incremental build. A fresh clone has no .build.
for entry in "$VERSION_DIR"/*; do
  case "$entry" in
    "$TOOLCHAIN" | "$SDKS_PATH" | "$BUILD_ARCHIVE") ;;
    *) rm -rf "$entry" ;;
  esac
done
if [ -e "$PROJECT_DIR/.build" ]; then
  log "note: .build already exists, so it is not restored from the build cache"
elif [ -f "$BUILD_ARCHIVE" ]; then
  START=$(date +%s)
  mkdir "$PROJECT_DIR/.build"
  if zstd -dcq --long=31 "$BUILD_ARCHIVE" | tar -xf - -C "$PROJECT_DIR/.build"; then
    log "restored .build from the build cache ($(du -sm "$PROJECT_DIR/.build" | cut -f1) MB) in $(seconds_since "$START")"
  else
    log "could not restore .build from the build cache; building from scratch"
    rm -rf "$PROJECT_DIR/.build"
  fi
fi

# 4. The wrapper the build command runs.
mkdir -p "$PROJECT_DIR/.vercel/bin"
cat > "$PROJECT_DIR/.vercel/bin/swift" << EOF
#!/usr/bin/env bash
# Written by vercel-install-swift.sh: runs the cached Swift $VERSION toolchain.
export SWIFT_VERCEL_SDKS_PATH='$SDKS_PATH'
status=0
'$TOOLCHAIN/usr/bin/swift' "\$@" || status=\$?
build='$PROJECT_DIR/.build'
if [ "\$status" -eq 0 ] && [ "\${1:-}" = package ] && [ -d "\$build" ]; then
  # Over Vercel's build cache limit the whole cache is dropped, toolchain included, so give up
  # incremental builds first.
  limit="\${SWIFT_VERCEL_MAX_BUILD_CACHE_MB:-2000}"
  size="\$(du -sm "\$build" | cut -f1)"
  if [ "\$size" -gt "\$limit" ]; then
    echo "swift-vercel: not caching the \${size} MB .build (over SWIFT_VERCEL_MAX_BUILD_CACHE_MB=\$limit)"
    rm -f '$BUILD_ARCHIVE'
  else
    # A POSIX tar keeps nanosecond file times, which the build cache's SquashFS would round.
    # zstd's long window also compresses the identical dependency checkouts SwiftPM keeps twice.
    set -o pipefail
    if tar --format=posix -cf - -C "\$build" . | zstd -T0 -3 --long=31 -q -f -o '$BUILD_ARCHIVE.partial'; then
      mv '$BUILD_ARCHIVE.partial' '$BUILD_ARCHIVE'
      echo "swift-vercel: saved the \${size} MB .build to the build cache"
    else
      rm -f '$BUILD_ARCHIVE.partial'
      echo "swift-vercel: could not save .build to the build cache"
    fi
  fi
fi
exit \$status
EOF
chmod +x "$PROJECT_DIR/.vercel/bin/swift"
log "ready: run .vercel/bin/swift package --disable-sandbox vercel"
