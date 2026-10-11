#!/usr/bin/env bash
# Installs the Static Linux SDK that matches the installed swift.org toolchain: reads the release
# from `swift --version`, looks up its SDK (version and checksum) in swift.org's release list and
# runs `swift sdk install`. CI uses it so any Swift release can be tested without hardcoding the
# SDK's URL and checksum.
#
#   scripts/install-static-sdk.sh [--dry-run]
#
#   --dry-run  Print the `swift sdk install` command instead of running it.
#
# Needs python3. SWIFT (default: swift) selects the toolchain.
set -euo pipefail

die() {
  echo "install-static-sdk: error: $*" >&2
  exit 1
}

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h | --help)
    sed -n '2,11s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  *) die "unknown argument '$1' (usage: $0 [--dry-run])" ;;
esac

SWIFT="${SWIFT:-swift}"
command -v python3 > /dev/null || die "python3 is required"
VERSION_OUTPUT="$("$SWIFT" --version 2>&1)" || die "could not run '$SWIFT --version'"

# Prints "<release name> <tag> <sdk version> <checksum>", or fails with a message.
read -r NAME TAG SDK_VERSION SDK_CHECKSUM < <(
  python3 - "$VERSION_OUTPUT" << 'EOF'
import json, re, sys, urllib.request

output = sys.argv[1]
first_line = output.splitlines()[0] if output else ""
url = "https://www.swift.org/api/v1/install/releases.json"

match = re.search(r"\(swift-(\d+(?:\.\d+){1,2})-RELEASE\)", output)
if not match:
    sys.exit(f"install-static-sdk: error: `swift` is not a swift.org release toolchain ({first_line}). "
             "The Static Linux SDK is published for swift.org releases only.")

def key(name):
    # 6.4 and 6.4.0 are the same release: swift.org names releases either way.
    numbers = [int(n) for n in name.split(".")]
    return numbers + [0] * (3 - len(numbers))

version = match.group(1)
try:
    with urllib.request.urlopen(url, timeout=60) as response:
        releases = json.load(response)
except Exception as error:
    sys.exit(f"install-static-sdk: error: could not download {url}: {error}")

release = next((r for r in releases if key(r["name"]) == key(version)), None)
if release is None:
    sys.exit(f"install-static-sdk: error: Swift {version} is not in {url}")
sdk = next((p for p in release.get("platforms", []) if p.get("platform") == "static-sdk"), None)
if sdk is None or not sdk.get("checksum"):
    sys.exit(f"install-static-sdk: error: swift.org has no Static Linux SDK for Swift {release['name']}")
print(release["name"], release["tag"], sdk.get("version", "0.0.1"), sdk["checksum"])
EOF
) || exit 1

SDK_ID="${TAG}_static-linux-${SDK_VERSION}"
URL="https://download.swift.org/$(echo "$TAG" | tr '[:upper:]' '[:lower:]')/static-sdk/$TAG/$SDK_ID.artifactbundle.tar.gz"
COMMAND=("$SWIFT" sdk install "$URL" --checksum "$SDK_CHECKSUM")

echo "install-static-sdk: Swift $NAME ($(echo "$VERSION_OUTPUT" | head -1)): Static Linux SDK $SDK_ID"
INSTALLED=0
"$SWIFT" sdk list 2> /dev/null | grep -qx "$SDK_ID" && INSTALLED=1
if [ "$DRY_RUN" = 1 ]; then
  [ "$INSTALLED" = 1 ] && echo "install-static-sdk: (already installed)"
  echo "${COMMAND[*]}"
elif [ "$INSTALLED" = 1 ]; then
  echo "install-static-sdk: already installed"
else
  "${COMMAND[@]}"
fi
