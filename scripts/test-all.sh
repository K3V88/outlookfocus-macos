#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
python3 scripts/test-native-host.py
npm --prefix chrome-extension run check
npm --prefix chrome-extension run test:browser
./scripts/build-native.sh
