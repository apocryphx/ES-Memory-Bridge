#!/usr/bin/env bash
#
# smoke-test.sh — initialize / tools/list / memory_cli / degraded-mode checks
# against a Debug build of the bridge.
#
# Run after a build; verifies the binary still satisfies the MCP handshake.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DERIVED="${ESMB_DERIVED:-/tmp/esmb-derived}"
APP="$DERIVED/Build/Products/Debug/ES_Memory_Bridge.app"
BIN="$APP/Contents/MacOS/ES_Memory_Bridge"
CACHE_DIR="$HOME/Library/Caches/com.elarity.es-memory-mcp"

if [[ ! -x "$BIN" ]]; then
    echo "[smoke] binary not found at $BIN — run a Debug build first" >&2
    echo "[smoke] hint: xcodebuild -project ES-Memory-Bridge.xcodeproj \\" >&2
    echo "       -scheme ES-Memory-Bridge -derivedDataPath \"$DERIVED\" build" >&2
    exit 1
fi

echo "[smoke] using $BIN"

pass=0
fail=0
check() {
    local name="$1"; shift
    if "$@"; then
        printf "[smoke] PASS %s\n" "$name"
        pass=$((pass + 1))
    else
        printf "[smoke] FAIL %s\n" "$name"
        fail=$((fail + 1))
    fi
}

# ─── Test 1: cold start (no cache) ─────────────────────────────────────────
echo "[smoke] T1: cold start"
rm -rf "$CACHE_DIR"
T1OUT=$(mktemp)
{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 3
} | "$BIN" 2>/dev/null > "$T1OUT"

t1_init_ok() {
    python3 -c "
import json
for line in open('$T1OUT'):
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except: continue
    if m.get('id') == 1 and 'result' in m and 'serverInfo' in m['result']: exit(0)
exit(1)
"
}
t1_tools_includes_memory_cli() {
    python3 -c "
import json
for line in open('$T1OUT'):
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except: continue
    if m.get('id') == 2:
        names = [t['name'] for t in m['result']['tools']]
        exit(0 if 'memory_cli' in names and 'memory_store' in names else 1)
exit(1)
"
}
check "T1.initialize returned serverInfo" t1_init_ok
check "T1.tools/list includes memory_cli + memory_store" t1_tools_includes_memory_cli

# ─── Test 2: warm start (cache present) ────────────────────────────────────
echo "[smoke] T2: warm start"
T2OUT=$(mktemp)
{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 1
} | "$BIN" 2>/dev/null > "$T2OUT"

t2_cache_loaded() {
    python3 -c "
import json
for line in open('$T2OUT'):
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except: continue
    if m.get('id') == 2:
        exit(0 if len(m['result']['tools']) > 0 else 1)
exit(1)
"
}
check "T2.warm start serves tools" t2_cache_loaded

# ─── Test 3: memory_cli parser ─────────────────────────────────────────────
# Only runs end-to-end if the server is reachable; otherwise the parser stage
# still runs locally and returns an error dict (which is fine — we're just
# checking that the bridge parses memory_cli locally and doesn't crash).
echo "[smoke] T3: memory_cli(man)"
T3OUT=$(mktemp)
{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_cli","arguments":{"expression":"man"}}}'
    sleep 2
} | "$BIN" 2>/dev/null > "$T3OUT"

t3_memory_cli_returns_content() {
    python3 -c "
import json
for line in open('$T3OUT'):
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except: continue
    if m.get('id') == 2:
        content = m.get('result', {}).get('content', [])
        exit(0 if content else 1)
exit(1)
"
}
check "T3.memory_cli(man) returns content" t3_memory_cli_returns_content

# ─── Test 4: bundle has tools-bootstrap.json ───────────────────────────────
echo "[smoke] T4: bundle contains bootstrap JSON"
t4_bundle_has_bootstrap() {
    [[ -s "$APP/Contents/Resources/tools-bootstrap.json" ]]
}
check "T4.tools-bootstrap.json in .app Resources/" t4_bundle_has_bootstrap

# ─── Test 5: .mcpb has bootstrap JSON ──────────────────────────────────────
MCPB="$ROOT/ES-Memory-Bridge.mcpb"
if [[ -f "$MCPB" ]]; then
    echo "[smoke] T5: .mcpb contains bootstrap JSON"
    t5_mcpb_has_bootstrap() {
        unzip -l "$MCPB" 2>/dev/null | grep -q "tools-bootstrap.json"
    }
    check "T5..mcpb contains tools-bootstrap.json" t5_mcpb_has_bootstrap
fi

# ─── Summary ───────────────────────────────────────────────────────────────
echo "[smoke] ${pass} passed, ${fail} failed"
exit $(( fail > 0 ? 1 : 0 ))
