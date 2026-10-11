#!/usr/bin/env bash
# Builds an example with the vercel plugin and runs the IPC contract harness against the
# real Linux binary.
#
# The binary is fully static, so on a Linux host of the same architecture (CI) the harness runs it
# directly. Elsewhere (macOS, or another architecture) it runs inside Amazon Linux 2023, the
# provided.al2023 base OS, with Docker.
#
# Usage: scripts/test-linux.sh [Examples/HelloVapor ...]   (default: all examples)
# Env:   ARCHITECTURE (arm64|x86_64), SKIP_BUILD=1 to reuse .vercel/output,
#        HARNESS (native|docker) to override where the binary runs.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

ARCHITECTURE="${ARCHITECTURE:-arm64}"
case "$ARCHITECTURE" in
  arm64) PLATFORM="linux/arm64"; MACHINE="aarch64" ;;
  x86_64) PLATFORM="linux/amd64"; MACHINE="x86_64" ;;
  *) echo "error: unsupported ARCHITECTURE '$ARCHITECTURE'" >&2; exit 1 ;;
esac

if [ -z "${HARNESS:-}" ]; then
  if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "$MACHINE" ]; then
    HARNESS="native"
  else
    HARNESS="docker"
  fi
fi
case "$HARNESS" in
  native | docker) ;;
  *) echo "error: HARNESS must be native or docker, got '$HARNESS'" >&2; exit 1 ;;
esac
echo "Running binaries: $HARNESS"

if [ "$#" -eq 0 ]; then
  set -- Examples/*/
fi

for EXAMPLE in "$@"; do
  EXAMPLE="${EXAMPLE%/}"
  echo "==> $EXAMPLE"
  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    (cd "$EXAMPLE" && swift package --disable-sandbox vercel --architecture "$ARCHITECTURE")
  fi

  FUNCTION="$EXAMPLE/.vercel/output/functions/index.func"
  APP_BINARY="$FUNCTION/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["executable"])' "$FUNCTION/vercel-bootstrap.json")"
  HANDLER="$FUNCTION/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["handler"])' "$FUNCTION/.vc-config.json")"

  # AWS Lambda runs a file named `bootstrap` in the function directory as its runtime, bypassing
  # Vercel's. The fake runtime cannot catch that, so check for it.
  if [ -e "$FUNCTION/bootstrap" ]; then
    echo "FAIL  the function contains a file named bootstrap" >&2
    exit 1
  fi

  # The bootstrap ships with every function, so it must stay small: no full Foundation (and its
  # ~40 MB of ICU data).
  if LC_ALL=C grep -q icudt "$HANDLER"; then
    echo "FAIL  the bootstrap links full Foundation/ICU" >&2
    exit 1
  fi
  echo "PASS  bootstrap does not link full Foundation/ICU ($(($(wc -c < "$HANDLER") / 1000000)) MB)"

  # Vapor 5 avoids full Foundation; VercelRuntime and VercelCache (with VercelHTTP and
  # AsyncHTTPClient) must not drag it back in. Hummingbird links Foundation itself, so it is exempt.
  if [ "$EXAMPLE" = "Examples/HelloVapor" ]; then
    if LC_ALL=C grep -q icudt "$APP_BINARY"; then
      echo "FAIL  $EXAMPLE links full Foundation/ICU" >&2
      exit 1
    fi
    echo "PASS  app does not link full Foundation/ICU ($(($(wc -c < "$APP_BINARY") / 1000000)) MB)"
  fi

  # Crons declared in vercel.json must be copied into the Build Output config.
  python3 - "$EXAMPLE" <<'EOF'
import json, os, sys
example = sys.argv[1]
source = os.path.join(example, "vercel.json")
expected = json.load(open(source)).get("crons", []) if os.path.exists(source) else []
actual = json.load(open(os.path.join(example, ".vercel/output/config.json"))).get("crons", [])
assert actual == expected, "config.json crons %r != vercel.json crons %r" % (actual, expected)
print("PASS  config.json crons match vercel.json (%d)" % len(actual))
EOF

  # Examples with WebSocket routes also get the WebSocket checks.
  HARNESS_FLAGS=""
  if grep -q 'HummingbirdWebSocket' "$ROOT/$EXAMPLE/Package.swift"; then
    HARNESS_FLAGS="--websocket"
  fi
  # Which swift-vercel-runtime products the app uses, matched exactly (`"Vercel"` is not
  # `"VercelRuntime"`).
  uses_product() {
    grep -Fq ".product(name: \"$1\"" "$ROOT/$EXAMPLE/Package.swift"
  }
  # Apps without VercelRuntime (directly or through the `Vercel` umbrella product) get every check
  # except the optional features it provides.
  if ! uses_product Vercel && ! uses_product VercelRuntime; then
    HARNESS_FLAGS="$HARNESS_FLAGS --minimal"
  fi
  # Apps with VercelCache (directly or through the umbrella) implement the Runtime Cache routes.
  if uses_product Vercel || uses_product VercelCache; then
    HARNESS_FLAGS="$HARNESS_FLAGS --runtime-cache"
  fi
  # Apps with the umbrella product implement the other feature module routes too.
  if uses_product Vercel; then
    HARNESS_FLAGS="$HARNESS_FLAGS --vercel-modules"
  fi
  if [ "$HARNESS" = "native" ]; then
    # shellcheck disable=SC2086
    python3 scripts/fake-runtime.py $HARNESS_FLAGS "$ROOT/$FUNCTION"
  else
    docker run --rm --platform "$PLATFORM" \
      -e HARNESS_FLAGS="$HARNESS_FLAGS" \
      -v "$ROOT/$FUNCTION:/var/task:ro" \
      -v "$ROOT/scripts/fake-runtime.py:/opt/fake-runtime.py:ro" \
      amazonlinux:2023 \
      sh -c 'command -v python3 >/dev/null || dnf install -y -q python3 >/dev/null; python3 /opt/fake-runtime.py $HARNESS_FLAGS /var/task'
  fi
done
