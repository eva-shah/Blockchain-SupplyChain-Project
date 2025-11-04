#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
TN="$HOME/fabric-samples/test-network"
cd "$TN"
# try absolute project path under Desktop, fallback to another common path
./network.sh deployCC -c main-supply -ccn trackchain -ccp "$HOME/Desktop/TrackChain/chaincode/trackchain-js" -ccl javascript
