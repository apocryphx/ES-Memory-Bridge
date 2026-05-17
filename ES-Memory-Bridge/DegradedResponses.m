//
//  DegradedResponses.m
//  ES-Memory-Bridge
//

#import "DegradedResponses.h"
#import "MCPFraming.h"

NSString * _Nullable ESMBDegradedResponseForRequest(NSDictionary *msg, NSArray *toolsList) {
    id rpcId = msg[@"id"];
    NSString *method = msg[@"method"];

    NSString *helpText = @"ES Memory is not running. Launch ES Memory.app from /Applications, "
                          "then ask Claude to retry.";

    if ([method isEqualToString:@"initialize"]) {
        return ESMBJSONRPCResult(rpcId, @{
            @"protocolVersion": @"2024-11-05",
            @"capabilities": @{ @"tools": @{} },
            @"serverInfo": @{
                @"name": @"ES Memory (offline)",
                @"version": @"0.0.0",
            },
            @"instructions": helpText,
        });
    }
    if ([method isEqualToString:@"tools/list"]) {
        return ESMBJSONRPCResult(rpcId, @{ @"tools": toolsList ?: @[] });
    }
    if ([method isEqualToString:@"tools/call"]) {
        NSString *toolName = msg[@"params"][@"name"] ?: @"this tool";
        NSString *callHelpText = [NSString stringWithFormat:
            @"ES Memory is not running. "
             "Launch ES Memory.app from /Applications to use '%@', "
             "then ask Claude to retry.", toolName];
        return ESMBJSONRPCResult(rpcId, @{
            @"content": @[ @{ @"type": @"text", @"text": callHelpText } ],
            @"isError": @YES,
        });
    }
    if ([method hasPrefix:@"notifications/"]) {
        return nil; // notifications expect no response
    }
    return ESMBJSONRPCError(rpcId, -32000, helpText);
}
