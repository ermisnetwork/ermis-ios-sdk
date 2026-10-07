#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPENDENCY_PATH="${1:-$REPOSITORY_ROOT/Vendor/open-mls-ios}"
METADATA="$DEPENDENCY_PATH/RELEASE_METADATA.json"
CHECKSUMS="$DEPENDENCY_PATH/ARTIFACT_CHECKSUMS.sha256"
GENERATED_SWIFT="$DEPENDENCY_PATH/Sources/open-mls-ios/open_mls_ios.swift"
XCFRAMEWORK="$DEPENDENCY_PATH/OpenMlsUniFFI.xcframework"
DEVICE_LIBRARY="$XCFRAMEWORK/ios-arm64/libopenmls_uniffi-aarch64-apple-ios.a"
SIMULATOR_LIBRARY="$XCFRAMEWORK/ios-arm64-simulator/libopenmls_uniffi-aarch64-apple-ios-sim.a"

cd "$REPOSITORY_ROOT"

if ! grep -Fq '.package(path: "Vendor/open-mls-ios")' Package.swift; then
    echo "Package.swift must link the reviewed Vendor/open-mls-ios package" >&2
    exit 1
fi

for required_file in \
    "$METADATA" \
    "$CHECKSUMS" \
    "$GENERATED_SWIFT" \
    "$XCFRAMEWORK/Info.plist" \
    "$DEVICE_LIBRARY" \
    "$SIMULATOR_LIBRARY"; do
    if [[ ! -f "$required_file" ]]; then
        echo "Missing OpenMLS artifact file: $required_file" >&2
        exit 1
    fi
done

jq -e '
    .schema_version == 1 and
    (.package_version | type == "string" and length > 0) and
    (.openmls_source_revision | test("^[0-9a-f]{40}$")) and
    (.openmls_tracked_diff_sha256 | test("^[0-9a-f]{64}$")) and
    (.cargo_lock_sha256 | test("^[0-9a-f]{64}$")) and
    .minimum_ios_version == "15.0" and
    (.slices | sort == ["arm64-apple-ios", "arm64-apple-ios-simulator"])
' "$METADATA" >/dev/null

required_capabilities=(
    process_message_at
    no_matching_key_package_error
    create_with_group_id
    load_from_storage_with_group_id
    save_state
    archive_epoch_v2
    decrypt_epoch_archive_v2
)
for capability in "${required_capabilities[@]}"; do
    if ! jq -e --arg capability "$capability" \
        '.required_ios_sdk_capabilities | index($capability) != null' \
        "$METADATA" >/dev/null; then
        echo "OpenMLS artifact metadata is missing capability: $capability" >&2
        exit 1
    fi
done

(
    cd "$DEPENDENCY_PATH"
    shasum -a 256 -c ARTIFACT_CHECKSUMS.sha256
)
plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null

if [[ "$(lipo -archs "$DEVICE_LIBRARY")" != "arm64" ]] ||
   [[ "$(lipo -archs "$SIMULATOR_LIBRARY")" != "arm64" ]]; then
    echo "OpenMLS XCFramework must contain arm64 device and simulator slices" >&2
    exit 1
fi

required_symbols=(
    uniffi_openmls_uniffi_fn_constructor_group_create_with_group_id
    uniffi_openmls_uniffi_fn_constructor_group_load_from_storage_with_group_id
    uniffi_openmls_uniffi_fn_method_group_process_message_at
)
for library in "$DEVICE_LIBRARY" "$SIMULATOR_LIBRARY"; do
    symbols="$(nm -gU "$library" 2>/dev/null)"
    for symbol in "${required_symbols[@]}"; do
        if ! grep -Fq "_$symbol" <<<"$symbols"; then
            echo "OpenMLS slice is missing ABI symbol $symbol: $library" >&2
            exit 1
        fi
    done
done

if ! grep -Fq 'func processMessageAt' "$GENERATED_SWIFT" ||
   ! grep -Fq 'createWithGroupId' "$GENERATED_SWIFT" ||
   ! grep -Fq 'loadFromStorageWithGroupId' "$GENERATED_SWIFT" ||
   ! grep -Fq 'case NoMatchingKeyPackage' "$GENERATED_SWIFT"; then
    echo "Generated Swift binding does not expose the required MLS compatibility API" >&2
    exit 1
fi

package_version="$(jq -r '.package_version' "$METADATA")"
source_revision="$(jq -r '.openmls_source_revision' "$METADATA")"
echo "ErmisChat/OpenMLS vendored artifact verified: $package_version ($source_revision)."
