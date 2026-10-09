#!/bin/zsh
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
#
# Builds and runs the dock/sleep/wake scenario harness against the CURRENT app sources.
#
# The real EventLogic, MonitorDock, Preferences, Heuristics and DebugLogKit are compiled
# as-is, except that Heuristics' two sensor entry points (evaluateDockWithRefresh and
# thunderboltSnapshotAsync) are rewritten to read the scripted world in Stubs.swift.
# ConnectivityController is replaced by a recorder, so no radio is ever touched.
# MonitorDock still registers real IOKit Thunderbolt notifications (read-only).
#
# Not part of the app target. Output: a PASS/FAIL line per check; exit 0 when all pass.
# The full log of the run is written to $BUILD/logs/harness.log.
#
#   Harness/run.sh            # summary
#   Harness/run.sh -v         # every check

set -euo pipefail
HERE="${0:A:h}"
SRC="$HERE/../Toggler"
BUILD="${TMPDIR:-/tmp}/TogglerHarness"
rm -rf "$BUILD"; mkdir -p "$BUILD/logs"

cp "$SRC"/{EventLogic,MonitorDock,Preferences,DebugLogKit,Notifications}.swift "$HERE"/{main,Stubs}.swift "$BUILD/"

python3 - "$SRC/Heuristics.swift" "$BUILD/Heuristics.swift" <<'EOF'
import sys
s = open(sys.argv[1]).read()
def swap(start, end, body):
    global s
    a = s.index(start); b = s.index(end, a)
    s = s[:a] + body + s[b:]
swap('    static func evaluateDockWithRefresh(', '    // MARK: – Ethernet presence detection',
'''    static func evaluateDockWithRefresh(threshold: Int, completion: @escaping @Sendable (Bool, Int, ThunderboltSnapshot) -> Void) {
        scoringQueue.asyncAfter(deadline: .now() + 0.05) {
            let r = HarnessWorld.reading()
            log("[harness] scripted sample -> isDocked=\\(r.0) score=\\(r.1) \\(r.2)")
            completion(r.0, r.1, r.2) } }

''')
swap('    static func thunderboltSnapshotAsync(', '    private static func readThunderboltSnapshot(',
'''    static func thunderboltSnapshotAsync(completion: @escaping @Sendable (ThunderboltSnapshot) -> Void) {
        scoringQueue.async { completion(HarnessWorld.reading().2) } }

''')
open(sys.argv[2], 'w').write(s)
EOF

( cd "$BUILD" && swiftc -swift-version 5 -suppress-warnings -o harness *.swift )
set +e
if [[ "${1:-}" == "-v" ]]; then "$BUILD/harness" "$BUILD/logs"; else "$BUILD/harness" "$BUILD/logs" | grep -E "^==|FAIL|CHECK"; fi
rc=${pipestatus[1]:-$?}
defaults delete harness >/dev/null 2>&1   # the harness's own preferences domain
echo "Log: $BUILD/logs/harness.log"
exit $rc
