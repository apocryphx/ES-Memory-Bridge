//
//  MCPServer.h
//  ES-Memory-Bridge
//
//  STDIO MCP server. Three-queue architecture, matching ES Kairos:
//    - esmb.mcp.read  (serial)     : stdin readabilityHandler → drainLines
//    - esmb.mcp.work  (concurrent) : one block per inbound JSON-RPC line
//    - esmb.mcp.write (serial)     : serializes stdout writes
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPServer : NSObject

+ (instancetype)shared;
- (void)start;

@end

NS_ASSUME_NONNULL_END
