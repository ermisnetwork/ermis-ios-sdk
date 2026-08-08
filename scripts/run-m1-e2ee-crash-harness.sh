#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <booted-simulator-udid>"
  exit 64
fi

simulator_udid="$1"
workspace=".swiftpm/xcode/package.xcworkspace"
scheme="ErmisChat-Package"
derived_data="${ERMIS_M1_CRASH_DERIVED_DATA:-/private/tmp/ermis-ios-m1-process-crash-derived}"
test_identifier="ErmisChatTests/E2eeProcessCrashHarnessTests/testProcessCrashBoundary"
environment_key="ERMIS_E2EE_M1_CRASH_PHASE"
destination="platform=iOS Simulator,id=${simulator_udid}"

clear_phase() {
  xcrun simctl spawn "${simulator_udid}" launchctl unsetenv "${environment_key}" >/dev/null
}

set_phase() {
  xcrun simctl spawn "${simulator_udid}" launchctl setenv "${environment_key}" "$1" >/dev/null
}

run_phase() {
  local phase="$1"
  set_phase "${phase}"
  xcodebuild test-without-building -quiet \
    -workspace "${workspace}" \
    -scheme "${scheme}" \
    -destination "${destination}" \
    -derivedDataPath "${derived_data}" \
    -only-testing:"${test_identifier}"
}

trap clear_phase EXIT INT TERM

xcodebuild build-for-testing -quiet \
  -workspace "${workspace}" \
  -scheme "${scheme}" \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}"

run_phase cleanup

for scenario in tcr005 tcr006 tcr007 tcr008; do
  set +e
  run_phase "${scenario}-seed"
  seed_status=$?
  set -e

  if [[ ${seed_status} -eq 0 ]]; then
    echo "${scenario}: seed phase did not terminate the XCTest process as required"
    exit 1
  fi

  run_phase "${scenario}-verify"
done

run_phase cleanup
clear_phase

echo "M1 E2EE process-crash harness passed TCR-005 through TCR-008"
