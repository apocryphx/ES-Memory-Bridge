//
//  main.m
//  ES-Memory-Bridge
//
//  Stdio↔HTTP bridge for the ES Memory MCP server.
//
//  Claude Desktop launches this CLT (packaged inside an .mcpb bundle) as a
//  subprocess. It reads JSON-RPC messages from stdin, forwards each to the
//  ES Memory app's locally-running HTTP server, and writes the response
//  back to stdout.
//
//  The bridge reads zero files. The host is expected to listen at a fixed
//  URL (localhost:59123/mcp) — an exotic, IANA-dynamic-range port chosen to
//  avoid conflicts with common local services (AirPlay sits on 5000, etc.).
//
//  If the host isn't reachable, the bridge responds locally to MCP requests
//  with a setup-help message so Claude can surface a clear error in the
//  conversation. It auto-recovers on the next successful forward.
//
//  No file IO = no TCC prompts, ever. That's the whole point of this
//  revision.
//

#import <Foundation/Foundation.h>
#include <signal.h>

static NSString *const kServerURL = @"http://localhost:59123/mcp";

static NSURL *gServerURL = nil;
static BOOL  gHostReachable = YES; // optimism; flipped on first forward failure

#pragma mark - HTTP Forwarding

static NSString *ForwardRequest(NSString *jsonLine, NSError **outError) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:gServerURL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [jsonLine dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json, text/event-stream" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 120.0; // MCP tool calls can be slow

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *responseBody = nil;
    __block NSError *requestError = nil;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            requestError = error;
        } else if (data) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status == 200) {
                responseBody = [[NSString alloc] initWithData:data
                                                     encoding:NSUTF8StringEncoding];
            }
            // 202 = notification acknowledged, no body expected.
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (outError) *outError = requestError;
    return responseBody;
}

#pragma mark - JSON-RPC Helpers

static NSString *EncodeJSON(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSString *JSONRPCResult(id rpcId, NSDictionary *result) {
    return EncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"result": result ?: @{}
    });
}

static NSString *JSONRPCError(id rpcId, NSInteger code, NSString *message) {
    return EncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"error": @{ @"code": @(code), @"message": message ?: @"Error" }
    });
}

#pragma mark - Degraded Mode

/// When the host isn't running, build a useful local response instead of
/// letting the connection fail silently. Stub initialize so Claude Desktop
/// keeps the connection open, surface a single setup-help "tool" via tools/list,
/// and on tools/call return human-readable text the user can act on.
static NSString *DegradedResponseForRequest(NSDictionary *msg) {
    id rpcId = msg[@"id"];
    NSString *method = msg[@"method"];

    NSString *helpText = @"ES Memory is not running. Launch ES Memory.app from /Applications, "
                          "then ask Claude to retry.";

    if ([method isEqualToString:@"initialize"]) {
        return JSONRPCResult(rpcId, @{
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
        return JSONRPCResult(rpcId, @{
            @"tools": @[ @{
                @"name": @"es_memory_setup",
                @"description": helpText,
                @"inputSchema": @{ @"type": @"object", @"properties": @{} },
            } ]
        });
    }
    if ([method isEqualToString:@"tools/call"]) {
        return JSONRPCResult(rpcId, @{
            @"content": @[ @{ @"type": @"text", @"text": helpText } ],
            @"isError": @YES,
        });
    }
    if ([method hasPrefix:@"notifications/"]) {
        return nil; // notifications expect no response
    }
    return JSONRPCError(rpcId, -32000, helpText);
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        gServerURL = [NSURL URLWithString:kServerURL];
        fprintf(stderr, "[es-bridge] forwarding to %s (static URL, no discovery)\n",
                kServerURL.UTF8String);

        NSFileHandle *stdinHandle  = [NSFileHandle fileHandleWithStandardInput];
        NSFileHandle *stdoutHandle = [NSFileHandle fileHandleWithStandardOutput];
        NSMutableData *buffer = [NSMutableData data];
        NSData *newlineData = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *chunk;

        while ((chunk = [stdinHandle availableData]) && chunk.length > 0) {
            [buffer appendData:chunk];

            while (YES) {
                NSRange newlineRange = [buffer rangeOfData:newlineData
                                                   options:0
                                                     range:NSMakeRange(0, buffer.length)];
                if (newlineRange.location == NSNotFound) break;

                NSData *lineData = [buffer subdataWithRange:
                    NSMakeRange(0, newlineRange.location)];
                [buffer replaceBytesInRange:
                    NSMakeRange(0, newlineRange.location + 1) withBytes:NULL length:0];

                NSString *line = [[NSString alloc] initWithData:lineData
                                                       encoding:NSUTF8StringEncoding];
                line = [line stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                if (line.length == 0) continue;

                NSError *error = nil;
                NSString *response = ForwardRequest(line, &error);
                NSString *output = nil;

                if (response) {
                    if (!gHostReachable) {
                        fprintf(stderr, "[es-bridge] host recovered — resuming forwarding\n");
                        gHostReachable = YES;
                    }
                    output = response;
                } else if (error) {
                    if (gHostReachable) {
                        fprintf(stderr, "[es-bridge] host unreachable: %s — degraded mode\n",
                                error.localizedDescription.UTF8String);
                        gHostReachable = NO;
                    }
                    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData
                                                                        options:0 error:nil];
                    if ([msg isKindOfClass:[NSDictionary class]]) {
                        output = DegradedResponseForRequest(msg);
                    }
                }
                // response nil + no error → 202 ack from host, no output needed.

                if (output) {
                    [stdoutHandle writeData:[[output stringByAppendingString:@"\n"]
                        dataUsingEncoding:NSUTF8StringEncoding]];
                }
            }
        }

        fprintf(stderr, "[es-bridge] stdin closed, exiting\n");
    }
    return 0;
}
