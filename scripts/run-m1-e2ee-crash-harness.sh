#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <booted-simulator-udid> [outgoing|receive|all]"
  exit 64
fi

simulator_udid="$1"
mode="${2:-outgoing}"
case "$mode" in
  outgoing) scenarios=(tcr005 tcr006 tcr007 tcr008) ;;
  receive) scenarios=(tcr009 tcr010 tcr011 tcr012) ;;
  all) scenarios=(tcr005 tcr006 tcr007 tcr008 tcr009 tcr010 tcr011 tcr012) ;;
  *) echo "Invalid harness mode" >&2; exit 64 ;;
esac
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
  python3 - "${workspace}" "${scheme}" "${destination}" "${derived_data}" "${test_identifier}" <<'PYRUN'
import subprocess, sys
command = ['xcodebuild', 'test-without-building', '-quiet', '-workspace', sys.argv[1],
           '-scheme', sys.argv[2], '-destination', sys.argv[3], '-derivedDataPath', sys.argv[4],
           '-only-testing:' + sys.argv[5], '-parallel-testing-enabled', 'NO',
           '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '60',
           '-collect-test-diagnostics', 'never', 'CODE_SIGNING_ALLOWED=NO']
try:
    result = subprocess.run(command, timeout=120)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    print('HARNESS_RUNNER_TIMEOUT: phase is unverified', flush=True)
    sys.exit(124)
PYRUN
}

trap clear_phase EXIT
trap 'exit 130' INT TERM

xcodebuild build-for-testing -quiet \
  -workspace "${workspace}" \
  -scheme "${scheme}" \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}"

run_phase cleanup

for scenario in "${scenarios[@]}"; do
  set +e
  run_phase "${scenario}-seed"
  seed_status=$?
  set -e

  if [[ ${seed_status} -eq 124 ]]; then
    echo "${scenario}: runner timeout; not an accepted process-death result"
    exit 124
  fi
  if [[ ${seed_status} -eq 0 ]]; then
    echo "${scenario}: seed phase did not terminate the XCTest process as required"
    exit 1
  fi

  run_phase "${scenario}-verify"
done

run_phase cleanup
clear_phase

echo "M1 E2EE process-crash harness passed mode=$mode scenarios=${#scenarios[@]}"
