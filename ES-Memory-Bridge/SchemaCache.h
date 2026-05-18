//
//  SchemaCache.h
//  ES-Memory-Bridge
//
//  Live proxy for the server's tools/list, with last-known-good disk
//  fallback for when the server isn't running.
//
//  Every call:
//    1. Forward tools/list to the server synchronously.
//    2a. On success: write the response to disk (overwrite), merge
//        memory_cli at index 0, return.
//    2b. On failure: read the on-disk last-known-good (written by some
//        prior successful fetch), merge memory_cli, return.
//    2c. No disk file either: return [memory_cli] only.
//
//  This replaces the previous design which also shipped a static
//  Resources/tools-bootstrap.json — that bootstrap could shadow a
//  running server with stale schemas whenever the disk cache was
//  empty, and required hand-edits in lockstep with the server. The
//  disk file is purely the bridge writing what it last saw; it's
//  always consistent with the most recent running server, so it can
//  never be more stale than "last time the server was up".
//
//  No TTL — the cache is overwritten on every successful fetch.
//
//  memory_cli is bridge-local; the server doesn't know about it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SchemaCache : NSObject

+ (instancetype)shared;

/// Synchronous fetch. Blocks for one server round-trip (typical <50ms;
/// Forwarder timeout 120s). Returns:
///   - live server response (and persists it to disk) when reachable
///   - last-known-good from disk when the server is down
///   - [memory_cli] only when neither is available
/// Never nil. memory_cli is always at index 0.
- (NSArray<NSDictionary *> *)currentTools;

@end

NS_ASSUME_NONNULL_END
