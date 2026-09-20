#!/bin/bash
# A first launch, without touching the browser you actually use.
#
#   ./fresh.sh          wipe the test world and open Search as a newcomer
#   ./fresh.sh again    open the test copy as it was left, no wipe
#
# A run with SEARCH_PROBE=1 keeps everything apart from the real one: its own
# folder under Application Support, its own settings suite, its own WebKit
# store for cookies and sign-ins. Wiping those three is a fresh install; the
# real session, pins, history and logins are never in reach of this script.
set -euo pipefail

cd "$(dirname "$0")"

if [ "${1:-}" != "again" ]; then
  rm -rf "$HOME/Library/Application Support/Search (test)"
  defaults delete com.officecommun.search.test 2>/dev/null || true
  # Store.probeStore, the fixed identifier of the test run's website data.
  rm -rf "$HOME/Library/WebKit/com.officecommun.search/WebsiteDataStore/5E4C0000-0000-4000-8000-000000000001"
  echo "test world wiped"
fi

[ -d "build/Search.app" ] || ./build.sh release
open -n --env SEARCH_PROBE=1 "build/Search.app"
