#!/usr/bin/env bash
# Builds an example with the vercel-build plugin and runs the IPC contract harness against the
# real Linux binary inside Amazon Linux 2023 (the provided.al2023 base OS).
#
# Usage: scripts/test-linux.sh [Examples/Vapor|Examples/Hummingbird ...]   (default: all examples)
# Env:   ARCHITECTURE (arm64|x86_64), SKIP_BUILD=1 to reuse .vercel/output.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

ARCHITECTURE="${ARCHITECTURE:-arm64}"
case "$ARCHITECTURE" in
  arm64) PLATFORM="linux/arm64" ;;
  x86_64) PLATFORM="linux/amd64" ;;
  *) echo "error: unsupported ARCHITECTURE '$ARCHITECTURE'" >&2; exit 1 ;;
esac

if [ "$#" -eq 0 ]; then
  set -- Examples/*/
fi

for EXAMPLE in "$@"; do
  EXAMPLE="${EXAMPLE%/}"
  echo "==> $EXAMPLE"
  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    (cd "$EXAMPLE" && swift package --disable-sandbox vercel-build --architecture "$ARCHITECTURE")
  fi

  # Vapor 5 avoids full Foundation; the runtime must not drag it (and ~40 MB of ICU data) back in.
  # Hummingbird links Foundation itself, so it is exempt.
  if [ "$EXAMPLE" = "Examples/HelloVapor" ]; then
    if LC_ALL=C grep -q icudt "$EXAMPLE/.vercel/output/functions/index.func/executable"; then
      echo "FAIL  $EXAMPLE links full Foundation/ICU" >&2
      exit 1
    fi
    echo "PASS  binary does not link full Foundation/ICU"
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

  # Examples that use the WebSocket adapter also get the WebSocket checks.
  HARNESS_FLAGS=""
  if grep -q 'VercelHummingbirdWebSocket' "$ROOT/$EXAMPLE/Package.swift"; then
    HARNESS_FLAGS="--websocket"
  fi
  docker run --rm --platform "$PLATFORM" \
    -e HARNESS_FLAGS="$HARNESS_FLAGS" \
    -v "$ROOT/$EXAMPLE/.vercel/output/functions/index.func:/var/task:ro" \
    -v "$ROOT/scripts/fake-runtime.py:/opt/fake-runtime.py:ro" \
    amazonlinux:2023 \
    sh -c 'command -v python3 >/dev/null || dnf install -y -q python3 >/dev/null; python3 /opt/fake-runtime.py $HARNESS_FLAGS /var/task/executable'
done
