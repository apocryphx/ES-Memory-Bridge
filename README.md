# ES Memory Bridge

A native macOS MCP bridge that connects Claude Desktop to the **ES Memory** app — a local memory archive designed by and for Claude. The bridge is a thin stdio↔HTTP shim: Claude Desktop launches it as a subprocess, it discovers the locally-running ES Memory server, and forwards JSON-RPC messages over HTTP.

## What this is

ES Memory is a macOS app that gives Claude persistent memory across sessions. It runs a local HTTP server backed by Core Data and a vector engine. **This bridge is the connector** that lets Claude Desktop (which speaks stdio MCP) talk to that server.

```
Claude Desktop ──stdio──> ES-Memory-Bridge ──HTTP──> ES Memory app
                                                     (Core Data + vectors,
                                                      runs on localhost)
```

The bridge itself does no storage. All memories live in the ES Memory app's local Core Data store.

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
xcodebuild -scheme ES-Memory-Bridge -configuration Release build
```

The build's "Package MCPB" run-script phase produces `ES-Memory-Bridge.mcpb` at the project root.

## How it works

1. Claude Desktop launches the bridge from the unpacked `.mcpb`.
2. The bridge reads `server.plist` from the host's sandbox container:
   ```
   ~/Library/Containers/com.elarity.es-memory-mcp/Data/Library/Application Support/ES-Memory/server.plist
   ```
   The host's bundle ID is a compile-time constant in [main.m](ES-Memory-Bridge/main.m) — the bridge has its own distinct ID (`com.elarity.es-memory-bridge`).
3. `server.plist` contains the full MCP endpoint URL (e.g. `http://localhost:5000/mcp`) and the host's version string.
4. The bridge forwards each JSON-RPC line from stdin to that URL via POST and writes the response back to stdout.

### When ES Memory isn't running

The bridge doesn't fail silently. Two safety nets:

- **Startup polling** — if `server.plist` is missing on launch, the bridge polls every 500ms for up to 5 seconds. Handles the common "Claude Desktop launched before ES Memory finished starting" race.
- **Degraded mode** — if polling still fails, the bridge stays alive and responds to `initialize` and `tools/list` with a stub containing a single `es_memory_setup` tool whose description tells the user to launch the ES Memory app. `tools/call` returns a human-readable error in the content. The bridge re-attempts discovery on every incoming request, so it auto-recovers once the host comes up.

This means the user sees a clear "launch ES Memory.app from /Applications" message inside Claude rather than a silent connection failure.

## Requires

The bridge uses a contract written by the host into `server.plist`:

| Key | Value |
|---|---|
| `url` | Full MCP endpoint URL including `/mcp` path |
| `version` | Host's `CFBundleShortVersionString` (logged on connect) |

The host also deletes `server.plist` on terminate so the bridge sees a clean "not running" state rather than a stale URL. Requires **ES Memory v1.0.4 or later**.

## Project structure

```
ES-Memory-Bridge/
├── ES-Memory-Bridge/
│   ├── main.m                     # Bridge implementation
│   └── Info.plist                 # CFBundleIdentifier = com.elarity.es-memory-bridge
├── ES-Memory-Bridge.xcodeproj/    # Xcode project
├── bundle/
│   ├── manifest.json              # MCPB manifest (v0.3)
│   ├── icon.png                   # Extension icon
│   └── server/                    # Binary copied here by build phase
└── ES-Memory-Bridge.mcpb          # Packaged bundle (built automatically)
```

## Privacy

The bridge makes no network requests beyond `localhost`. Nothing leaves your machine. See [PRIVACY.md](PRIVACY.md).

## License

MIT — see [LICENSE](LICENSE).
