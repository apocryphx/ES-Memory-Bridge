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
2. The bridge forwards each JSON-RPC line from stdin to a fixed URL:
   ```
   http://localhost:59123/mcp
   ```
   It writes the HTTP response back to stdout. That's the whole hot path.

The bridge reads **zero files** — no config, no discovery, no shared state with the host. No file IO means no macOS TCC prompts, ever.

### The port choice

59123 is deliberately exotic: in the IANA dynamic/private range (49152-65535), not associated with any common service. Port 5000 (the common default for local HTTP dev servers) is used by macOS AirPlay Receiver, which was the motivation for moving off it.

### When ES Memory isn't running

The bridge doesn't fail silently. If the HTTP forward fails (host not running, or went down mid-session), the bridge enters degraded mode:

- `initialize` returns a stub with `serverInfo.name: "ES Memory (offline)"` and an `instructions` field telling the user to launch the app.
- `tools/list` returns one tool: `es_memory_setup`, whose description also tells the user to launch the app.
- `tools/call` returns `isError: true` with human-readable setup text.

On every subsequent request the bridge attempts the forward again, so the moment the host comes up the bridge auto-recovers and resumes normal forwarding. The user sees a clear, actionable message inside Claude instead of a silent connection failure.

## Requires

**ES Memory v1.0.5 or later**, configured to bind to port 59123. (Earlier versions used dynamic port selection with discovery via `server.plist`; v1.0.5 binds to a fixed port and needs no discovery.)

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
