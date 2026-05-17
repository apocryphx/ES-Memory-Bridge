//
//  Forwarder.h
//  ES-Memory-Bridge
//
//  HTTP forwarding to the ES Memory host's MCP endpoint.
//
//  The bridge POSTs JSON-RPC envelopes to a fixed URL — currently
//  http://localhost:59123/mcp, an IANA-dynamic-range port chosen to avoid
//  conflicts with common local services. Reachability state is tracked here
//  (single source of truth) so degraded-mode transitions log once, not
//  per-call. State is guarded by an os_unfair_lock — multiple work-queue
//  threads will read/write it once the NSApplication MCPServer is in place.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Forwarder : NSObject

+ (instancetype)shared;

/// Synchronous POST. Blocks the caller until the response arrives (semaphore
/// wait, 120s timeout). Returns the response body on HTTP 200, nil on HTTP
/// 202 (notification ack) or transport failure. Populates *outError on
/// transport failure.
///
/// Used by ESBridgeCLI's stage executor — pipeline stages are intrinsically
/// sequential, so the caller wants synchronous semantics.
- (nullable NSString *)forwardLine:(NSString *)jsonLine error:(NSError **)outError;

/// Async variant. Completion fires on URLSession's internal queue with the
/// same return semantics as the sync version (`response` nil on transport
/// failure or HTTP 202 ack).
///
/// Used by MCPServer's top-level dispatch — frees the work-queue thread to
/// handle the next inbound line while HTTP is in flight.
- (void)forwardLineAsync:(NSString *)jsonLine
              completion:(void (^)(NSString * _Nullable response,
                                   NSError * _Nullable error))completion;

/// Current reachability — last forward succeeded (YES) or failed (NO).
/// Read-only; transitions are managed internally and logged once.
@property (atomic, readonly) BOOL hostReachable;

@end

#pragma mark - C-compatible facade for ESBridgeCLI

/// Synchronous forward, matching the original main.m symbol that
/// ESBridgeCLI.h:66 forward-declares. Thin wrapper over [Forwarder shared].
NSString * _Nullable ForwardRequest(NSString *jsonLine, NSError * _Nullable * _Nullable outError);

NS_ASSUME_NONNULL_END
