# ES Memory Bridge

A native macOS MCP bridge that connects Claude Desktop to the **ES Memory** app — a local memory archive designed with and for Claude. As of v2.0, the bridge is no longer a thin pass-through: it hosts a Unix-pipeline-style search surface (`memory_cli`) on top of the server's per-tool MCP API. The server stays minimal and stable; the bridge is where the cognitive interface layer lives — and where it can iterate fast.

## What this is

ES Memory is a macOS app that gives Claude persistent memory across sessions. It runs a local HTTP server backed by Core Data and a vector engine. **This bridge is the cognitive layer** between Claude Desktop and that server: it parses pipeline expressions, composes them into one (or, rarely, two) HTTP calls to the server, and returns shell-shaped diagnostics that Claude reads as cognitive scaffolding.

```
Claude Desktop ──stdio──> ES-Memory-Bridge ──HTTP──> ES Memory app
   (sees one tool         (parses pipeline,           (per-tool MCP
    memory_cli + CRUD)     composes server calls,      surface — stable
                           builds diagnostic)          across bridge versions)
```

The bridge does no storage. All memories live in the ES Memory app's local Core Data store. The bridge can be iterated independently of the server, and a future bridge variant could present a different cognitive surface (e.g., for a different LLM with different priors) over the same server API.

## Requirements

- macOS (Apple Silicon or Intel)
- The **ES Memory** app installed and running locally (the bridge cannot work without it)
- Claude Desktop

## Install

### Option 1: Download the `.mcpb` bundle

1. Download [`ES-Memory-Bridge.mcpb`](https://github.com/apocryphx/ES-Memory-Bridge/releases/latest/download/ES-Memory-Bridge.mcpb)
2. Open Claude Desktop → Settings
3. Drag the `.mcpb` onto **Drag .MCPB or .DXT files here to install**
4. Make sure the ES Memory app is running

### Option 2: Build from source

Requires Xcode and Node (for `npx @anthropic-ai/mcpb pack`).

```bash
git clone https://github.com/apocryphx/ES-Memory-Bridge.git
cd ES-Memory-Bridge
xcodebuild -project ES-Memory-Bridge.xcodeproj -scheme ES-Memory-Bridge -configuration Release build
```

The build's "Package MCPB" run-script phase produces `ES-Memory-Bridge.mcpb` at the project root. `scripts/package-mcpb.sh` does the same end-to-end with a clean isolated derived-data path (suitable for release). `scripts/smoke-test.sh` verifies cold-start, warm-start, and `memory_cli` behavior against a Debug build.

## How it works

Claude Desktop launches the bridge from the unpacked `.mcpb` and speaks JSON-RPC to it over stdio. The bridge is an `NSApplication` accessory (`LSUIElement=true`) — no Dock icon, no menubar item — with a three-queue MCP server (read / work / write) running on the main runloop. The AppKit lifecycle is in place so a future preferences window or status item can attach without re-architecting; today it has no UI.

Each request is handled in one of three ways:

1. **`tools/list`** — answered locally from a cached schema. On launch the bridge fetches `tools/list` from the server and persists it to `~/Library/Caches/com.elarity.es-memory-mcp/tools.json`. Subsequent launches serve from the cache and refresh asynchronously when stale (default 24h, override via the `ESMBSchemaCacheTTL` `NSUserDefaults` key). Cold start with no cache and no server falls back to a bootstrap JSON shipped inside the `.app` bundle. `memory_cli` is the bridge-local tool — always present, merged in memory only.

2. **`tools/call(memory_cli, expression)`** — handled locally by the bridge's CLI executor. The expression is a Unix-style pipeline (`lfind --tag X | w2vgrep "Y" | head 5`); the executor parses it, composes server calls (typically one with rich filter parameters, sometimes two with bridge-side intersection for compositions like `discover | w2vgrep`), and returns a single response with both per-stage pipeline diagnostics and final results. Try `memory_cli("man")` to see the command vocabulary.

3. **Everything else** — forwarded transparently to the server at `http://localhost:59123/mcp`. CRUD operations, comments, links, attachments all pass through unchanged.

The bridge writes one file: the schema cache at `~/Library/Caches/com.elarity.es-memory-mcp/tools.json`. That path is TCC-unrestricted, so no privacy prompts. No config files, no host discovery, no shared state with the server.

### Why a CLI in the bridge

The CLI is composition logic. It has no business in the data server. Putting it in the bridge gives three things: the server stays minimal and stable (its API is the same as before v2.0); the bridge can iterate fast (rebuild seconds, no CloudKit reconnect needed); and a future Bridge-for-Gemini or Bridge-for-Local-Gemma can present a different cognitive surface over the same data API, tailored to whatever priors that LLM brings.

### The port choice

59123 is deliberately exotic: in the IANA dynamic/private range (49152-65535), not associated with any common service. Port 5000 (the common default for local HTTP dev servers) is used by macOS AirPlay Receiver, which was the motivation for moving off it.

### When ES Memory isn't running

The bridge doesn't fail silently. If the HTTP forward fails (host not running, or went down mid-session), the bridge enters degraded mode:

- `initialize` returns a stub with `serverInfo.name: "ES Memory (offline)"` and an `instructions` field telling the user to launch the app.
- `tools/list` is unaffected — it's always served from the bridge's cached schema (disk cache, falling back to the bundled bootstrap), host up or down.
- `tools/call(memory_cli, ...)` will fail at the first server-call stage when the bridge tries to reach the host; the response surfaces a clear error.
- Other `tools/call` returns `isError: true` with a tool-specific message: _"ES Memory is not running. Launch ES Memory.app from /Applications to use '<tool>', then ask Claude to retry."_

On every subsequent request the bridge attempts the forward again, so the moment the host comes up the bridge auto-recovers.

## Requires

- **ES Memory v1.0.5 or later**, configured to bind to port 59123. (Earlier versions used dynamic port selection with discovery via `server.plist`; v1.0.5 binds to a fixed port and needs no discovery.)
- For the v2.0 bridge: the server's per-tool MCP API (`memory_search`, `memory_grep`, `memory_recent`, `memory_tagged`, `memory_discover`) must be available — the bridge's CLI dispatches to these internally. Any ES Memory build with the pre-chained-search API works.

## Project structure

```
ES-Memory-Bridge/
├── ES-Memory-Bridge/
│   ├── main.m                          # NSApplication entry, sets up AppDelegate
│   ├── AppDelegate.{h,m}               # lifecycle; starts SchemaCache + MCPServer
│   ├── MCPServer.{h,m}                 # three-queue STDIO loop, dispatch, EOF drain
│   ├── SchemaCache.{h,m}               # disk cache + bundle bootstrap + async refresh
│   ├── Forwarder.{h,m}                 # HTTP forward (sync + async), reachability state
│   ├── MCPFraming.{h,m}                # JSON-RPC 2.0 framing helpers
│   ├── DegradedResponses.{h,m}         # host-offline fallback responses
│   ├── ESBridgeCLI.{h,m}               # memory_cli tokenizer, parser, executor
│   ├── ESMemoryBridge.entitlements     # app-sandbox = false (required for STDIO)
│   ├── Resources/
│   │   └── tools-bootstrap.json        # cold-start schema fallback (server-derived)
│   └── Info.plist                      # LSUIElement=true, NSPrincipalClass=NSApplication
├── ES-Memory-Bridge.xcodeproj/         # Xcode project (filesystem-synchronized group)
├── bundle/
│   ├── manifest.json                   # MCPB manifest (v0.3, bundle version 2.6.0)
│   ├── icon.png                        # extension icon
│   └── server/                         # .app staged here by build phase (gitignored)
├── scripts/
│   ├── extract-bootstrap-tools.sh      # regenerate Resources/tools-bootstrap.json
│   ├── smoke-test.sh                   # cold/warm/memory_cli verification
│   └── package-mcpb.sh                 # clean Release → .mcpb
└── ES-Memory-Bridge.mcpb               # packaged bundle (built automatically)
```

## Privacy

The bridge makes no network requests beyond `localhost`. Nothing leaves your machine. See [PRIVACY.md](PRIVACY.md).

## License

MIT — see [LICENSE](LICENSE).
