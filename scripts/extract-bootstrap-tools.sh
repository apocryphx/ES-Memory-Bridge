#!/usr/bin/env bash
#
# extract-bootstrap-tools.sh
#
# Runs the current bridge binary, captures its tools/list response, strips
# memory_cli (merged at runtime by SchemaCache), and writes the result to
# Resources/tools-bootstrap.json — the cold-start fallback when no server
# is running and no on-disk cache yet exists.
#
# Re-run this script whenever the server's tool surface evolves enough that
# a stale cold-start fallback would be misleading. The 24h-TTL refresh
# handles the common case at runtime.
#
# Requires: jq, xcodebuild.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DERIVED="/tmp/esmb-bootstrap-derived"
echo "[bootstrap] building bridge into $DERIVED" >&2
xcodebuild -project "ES-Memory-Bridge.xcodeproj" \
           -scheme "ES-Memory-Bridge" \
           -configuration Debug \
           -derivedDataPath "$DERIVED" \
           build >/dev/null

BIN="$DERIVED/Build/Products/Debug/ES-Memory-Bridge"
[[ -x "$BIN" ]] || { echo "[bootstrap] binary not found at $BIN" >&2; exit 1; }

OUT="$ROOT/ES-Memory-Bridge/Resources/tools-bootstrap.json"
mkdir -p "$(dirname "$OUT")"

echo "[bootstrap] capturing tools/list response" >&2
RESPONSE=$({
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 2
} | "$BIN" 2>/dev/null)

# Extract the tools/list response (id=2), strip memory_cli, pretty-print.
echo "$RESPONSE" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if msg.get('id') == 2:
        tools = msg['result']['tools']
        filtered = [t for t in tools if t.get('name') != 'memory_cli']
        print(json.dumps(filtered, indent=2, ensure_ascii=False))
        sys.exit(0)
sys.exit(1)
" > "$OUT"

COUNT=$(python3 -c "import json; print(len(json.load(open('$OUT'))))")
echo "[bootstrap] wrote $OUT ($COUNT tools, memory_cli excluded)" >&2
