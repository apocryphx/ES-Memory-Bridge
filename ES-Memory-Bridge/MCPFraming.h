//
//  MCPFraming.h
//  ES-Memory-Bridge
//
//  JSON-RPC 2.0 framing helpers. Extracted from main.m so the same encoding
//  primitives are reachable from any module that produces a wire message
//  (MCPServer, SchemaCache during refresh, DegradedResponses).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Encode an NSDictionary as a compact JSON string. Returns nil on failure.
NSString * _Nullable ESMBEncodeJSON(NSDictionary *obj);

/// Build a JSON-RPC 2.0 success response. `rpcId` of nil becomes JSON null.
NSString * _Nullable ESMBJSONRPCResult(id _Nullable rpcId, NSDictionary *result);

/// Build a JSON-RPC 2.0 error response. `rpcId` of nil becomes JSON null.
NSString * _Nullable ESMBJSONRPCError(id _Nullable rpcId, NSInteger code, NSString *message);

NS_ASSUME_NONNULL_END
