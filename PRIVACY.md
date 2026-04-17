# Privacy Policy

**ES Memory Bridge**
Last updated: April 16, 2026

## Overview

ES Memory Bridge is a local connector between Claude Desktop and the ES Memory app. It does not collect, store, or transmit any data outside your machine.

## Data Flow

The bridge sits between two local processes:

```
Claude Desktop ──stdio──> ES-Memory-Bridge ──HTTP localhost──> ES Memory app
```

- **Stdio side**: receives JSON-RPC requests from Claude Desktop on stdin, writes responses to stdout. Standard MCP transport.
- **HTTP side**: forwards each request to the ES Memory app's HTTP server, bound only to `localhost` (loopback). The bridge discovers the server URL by reading `server.plist` from the ES Memory app's sandbox container.

The bridge itself stores nothing. All memories are stored by the ES Memory app in its local Core Data store on your machine.

## Data Collection

The bridge collects **no data**. Specifically:

- **No analytics or telemetry** are sent anywhere
- **No external network requests** are made — communication is loopback-only (`localhost`)
- **No files** outside the ES Memory app's sandbox container are read
- **No data** is shared with third parties
- **Nothing is cached or persisted** by the bridge — it is a pure forwarder

## Third-Party Sharing

No data is shared with any third party. The bridge has no remote network capability.

## Contact

For questions about this privacy policy, open an issue at:
https://github.com/apocryphx/ES-Memory-Bridge/issues
