#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_VERSION="0.1.0-m0.1"
EXPECTED_REVISION="1479aad14ab85bce7f884c1dd1dfa42006ed9834"
DEPENDENCY_PATH="${1:-$REPOSITORY_ROOT/.build/checkouts/open-mls-ios}"

cd "$REPOSITORY_ROOT"

if ! grep -Fq 'url: "https://github.com/ermisnetwork/open-mls-ios.git"' Package.swift ||
   ! grep -Fq "exact: \"$EXPECTED_VERSION\"" Package.swift; then
    echo "Package.swift must pin open-mls-ios exactly to $EXPECTED_VERSION" >&2
    exit 1
fi

if [[ ! -d "$DEPENDENCY_PATH/.git" ]]; then
    echo "Resolved open-mls-ios checkout not found at $DEPENDENCY_PATH" >&2
    exit 1
fi

resolved_revision="$(git -C "$DEPENDENCY_PATH" rev-parse HEAD)"
if [[ "$resolved_revision" != "$EXPECTED_REVISION" ]]; then
    echo "Resolved open-mls-ios revision $resolved_revision; expected $EXPECTED_REVISION" >&2
    exit 1
fi

resolved_version="$(jq -r '.package_version' "$DEPENDENCY_PATH/RELEASE_METADATA.json")"
if [[ "$resolved_version" != "$EXPECTED_VERSION" ]]; then
    echo "Resolved metadata version $resolved_version; expected $EXPECTED_VERSION" >&2
    exit 1
fi

"$DEPENDENCY_PATH/scripts/verify-release-artifact.sh"

echo "ErmisChat/OpenMLS compatibility pin verified at $EXPECTED_VERSION ($EXPECTED_REVISION)."
