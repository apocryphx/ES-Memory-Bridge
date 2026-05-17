//
//  DegradedResponses.h
//  ES-Memory-Bridge
//
//  Local responses produced when the ES Memory host is unreachable. Stubs
//  initialize so Claude Desktop keeps the connection open, surfaces the
//  full tool schema via tools/list so Claude still knows what's available,
//  and on tools/call returns a tool-specific error so the user knows
//  exactly what to start and why.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Build a degraded JSON-RPC response for `msg`. `toolsList` is the array
/// served for tools/list — the caller owns the schema source (StaticToolsList
/// today, SchemaCache.currentTools later) so this module stays decoupled.
/// Returns nil for messages that expect no response (e.g. notifications/*).
NSString * _Nullable ESMBDegradedResponseForRequest(NSDictionary *msg, NSArray *toolsList);

NS_ASSUME_NONNULL_END
