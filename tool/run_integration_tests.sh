#!/usr/bin/env bash
# Runs every integration test file, one flutter invocation per file.
#
#   tool/run_integration_tests.sh            runs on the host (flutter-tester):
#                                            no phone or emulator needed
#   tool/run_integration_tests.sh <device>   runs on a phone / emulator, e.g.
#                                            tool/run_integration_tests.sh 55VSAUJFYLDIIFBU
#
# Why not plain `flutter test integration_test`? With a phone attached that
# command installs and runs the tests ON THE PHONE (replacing the app), and
# with the host tester several files in one run fail to launch after the first
# one ("The log reader failed unexpectedly"). One file per run is reliable.
set -u
cd "$(dirname "$0")/.."

DEVICE="${1:-flutter-tester}"
failed=0

for file in integration_test/*_test.dart; do
  echo
  echo "=== $file (device: $DEVICE)"
  if ! flutter test "$file" -d "$DEVICE"; then
    failed=1
  fi
done

echo
if [ "$failed" -eq 0 ]; then
  echo "All integration tests passed."
else
  echo "Some integration tests FAILED."
fi
exit "$failed"
