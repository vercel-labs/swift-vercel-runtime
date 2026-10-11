#!/usr/bin/env bash
# Installs the swift.org toolchain and the Static Linux SDK in a Vercel build, so a Git deployment
# can run `swift package vercel` itself. Use it as the project's Install Command:
#
#   Install Command: curl -fsSL https://raw.githubusercontent.com/vercel-labs/swift-vercel-runtime/main/scripts/vercel-install-swift.sh | bash
#   Build Command:   .vercel/bin/swift package --disable-sandbox vercel
#
# Vercel saves <repository root>/.vercel/cache after every build and restores it before the next
# one, so only a project's first build downloads Swift. Everything lives in
# .vercel/cache/swift/<version>: the toolchain (without the debugger, SourceKit and other tools a
# server build does not use), the SDK, and the build directory for incremental builds. Other
# versions are deleted to stay under the build cache size limit.
#
# The project's .build becomes a link to the cached build directory. The build command runs
# .vercel/bin/swift, a wrapper this script writes into the project: it points
# `swift package vercel` at the cached SDK, and drops the build directory from the cache if it
# grows past SWIFT_VERCEL_MAX_BUILD_CACHE_MB.
#
# Environment:
#   SWIFT_VERSION                    Swift release, like 6.4.0 or 6.4 (latest 6.4.x). Defaults to
#                                    the project's .swift-version file, then the latest release.
#   SWIFT_VERCEL_MAX_BUILD_CACHE_MB  Largest build directory to keep cached (default 2000).
set -euo pipefail

log() { echo "swift-vercel: $*"; }
die() {
  echo "swift-vercel: error: $*" >&2
  exit 1
}
seconds_since() { echo "$(($(date +%s) - $1))s"; }

[ "$(uname -s)" = "Linux" ] || die "this installs Swift in Vercel's Linux build image. On your own machine, follow the README instead."
for tool in curl tar gpg node; do
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
    const candidates = releases
      .filter((r) => !requested || r.name === requested || r.name.startsWith(requested + "."))
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
BUILD_DIR="$VERSION_DIR/build"
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
  log "installed the Static Linux SDK in $(seconds_since "$START")"
fi

# 3. The package's .build, in the cache: resolved dependencies, the compiled plugin and (in
# .build/vercel) the plugin's incremental build. A fresh clone has no .build; leave a real one alone.
mkdir -p "$BUILD_DIR"
if [ -L "$PROJECT_DIR/.build" ] || [ ! -e "$PROJECT_DIR/.build" ]; then
  ln -sfn "$BUILD_DIR" "$PROJECT_DIR/.build"
else
  log "note: $PROJECT_DIR/.build exists, so builds are not incremental"
fi

# 4. The wrapper the build command runs.
mkdir -p "$PROJECT_DIR/.vercel/bin"
cat > "$PROJECT_DIR/.vercel/bin/swift" << EOF
#!/usr/bin/env bash
# Written by vercel-install-swift.sh: runs the cached Swift $VERSION toolchain.
export SWIFT_VERCEL_SDKS_PATH='$SDKS_PATH'
status=0
'$TOOLCHAIN/usr/bin/swift' "\$@" || status=\$?
# Over Vercel's build cache limit the whole cache is dropped, toolchain included, so give up the
# build directory (incremental builds) first.
limit="\${SWIFT_VERCEL_MAX_BUILD_CACHE_MB:-2000}"
if [ -d '$BUILD_DIR' ]; then
  size="\$(du -sm '$BUILD_DIR' | cut -f1)"
  if [ "\$size" -gt "\$limit" ]; then
    echo "swift-vercel: not caching the \${size} MB build directory (over SWIFT_VERCEL_MAX_BUILD_CACHE_MB=\$limit)"
    rm -rf '$BUILD_DIR'
  fi
fi
exit \$status
EOF
chmod +x "$PROJECT_DIR/.vercel/bin/swift"
log "ready: run .vercel/bin/swift package --disable-sandbox vercel"
