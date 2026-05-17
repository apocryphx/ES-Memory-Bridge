//
//  MCPFraming.m
//  ES-Memory-Bridge
//

#import "MCPFraming.h"

NSString * _Nullable ESMBEncodeJSON(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSString * _Nullable ESMBJSONRPCResult(id _Nullable rpcId, NSDictionary *result) {
    return ESMBEncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"result": result ?: @{}
    });
}

NSString * _Nullable ESMBJSONRPCError(id _Nullable rpcId, NSInteger code, NSString *message) {
    return ESMBEncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"error": @{ @"code": @(code), @"message": message ?: @"Error" }
    });
}
