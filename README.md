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
2. The bridge reads its own `CFBundleIdentifier` from the embedded Info.plist (`com.elarity.es-memory-mcp` — same as the host app).
3. From that, it derives the host's sandbox-container path and reads `server.plist`:
   ```
   ~/Library/Containers/com.elarity.es-memory-mcp/Data/Library/Application Support/ES-Memory/server.plist
   ```
4. `server.plist` contains the URL of the locally-running HTTP server (e.g. `http://localhost:5000/`).
5. The bridge forwards each JSON-RPC line from stdin to that URL via POST and writes the response back to stdout.

If `server.plist` is missing or the server isn't running, the bridge writes a diagnostic to stderr and exits non-zero.

## Project structure

```
ES-Memory-Bridge/
├── ES-Memory-Bridge/
│   ├── main.m                     # Bridge implementation
│   └── Info.plist                 # CFBundleIdentifier = com.elarity.es-memory-mcp
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
