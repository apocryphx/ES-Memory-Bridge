//
//  SchemaCache.h
//  ES-Memory-Bridge
//
//  Cached JSON schema served on tools/list. Replaces the prior compile-time
//  StaticToolsList — the source of truth is now the ES Memory server's own
//  tools/list response, fetched once at launch and persisted to
//  ~/Library/Caches/com.elarity.es-memory-mcp/tools.json.
//
//  Cold-start fallback: the .app bundle ships Resources/tools-bootstrap.json
//  derived from the last-known server schema. Without it, a first-run with
//  no server would surface an empty tools list.
//
//  memory_cli is bridge-local — the server doesn't know about it. It's
//  merged into currentTools in memory only, never persisted to disk.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SchemaCache : NSObject

+ (instancetype)shared;

/// Synchronous load. Reads the on-disk cache if present, falls back to the
/// bootstrap JSON in the app bundle, then to `inMemoryFallback` (CLT-only
/// transitional path — pass StaticToolsList() until the bundle has
/// Resources/tools-bootstrap.json). Always populates currentTools before
/// returning. Schedules an async refresh from the server. Must be invoked
/// before MCPServer starts handling tools/list.
- (void)loadOnStartupWithFallback:(nullable NSArray<NSDictionary *> *)inMemoryFallback;

/// The array currently served for tools/list. Includes memory_cli at index 0.
/// Thread-safe; returns a snapshot pointer that won't be torn by a concurrent
/// refresh.
- (NSArray<NSDictionary *> *)currentTools;

/// Cache age vs. TTL (default 24h, override via NSUserDefaults key
/// `ESMBSchemaCacheTTL` as seconds). Returns YES on first run.
- (BOOL)isStale;

/// Fetch tools/list from the server in the background. Rewrites disk cache
/// and atomically swaps currentTools on success. Coalesces concurrent calls.
/// On failure, keeps the previous snapshot and logs to stderr.
- (void)refreshAsync;

@end

NS_ASSUME_NONNULL_END
