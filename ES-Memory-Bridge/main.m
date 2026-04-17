//
//  main.m
//  ES-Memory-Bridge
//
//  Stdio↔HTTP bridge for the ES Memory MCP server.
//
//  Claude Desktop launches this CLT (packaged inside an .mcpb bundle) as a
//  subprocess. It reads JSON-RPC messages from stdin, forwards each to the
//  ES Memory app's locally-running HTTP server, and writes the response to
//  stdout.
//
//  Discovery: reads server.plist from the host's sandbox container at
//      ~/Library/Containers/<HOST_BUNDLE_ID>/Data/Library/Application Support/ES-Memory/server.plist
//  The plist contains the full MCP endpoint URL and the host's version.
//
//  If the host isn't running on startup, the bridge polls for ~5s, then enters
//  a degraded mode that responds to MCP requests locally with a setup-help
//  message instead of failing silently. It re-attempts discovery on every
//  request, so it auto-recovers when the host comes up.
//

#import <Foundation/Foundation.h>
#include <signal.h>

// The host app's bundle ID. The bridge reads server.plist from the host's
// sandbox container at this ID. Change this and the bridge points at a
// different host app.
#define HOST_BUNDLE_ID @"com.elarity.es-memory-mcp"

static NSURL *gServerURL = nil;
static NSString *gServerVersion = nil;

#pragma mark - Server Discovery

/// Read server.plist from the host's sandbox container.
/// quiet=YES suppresses stderr output (used during polling so we don't spam logs).
static NSURL *DiscoverServerURL(BOOL quiet) {
    NSString *plistPath = [NSString stringWithFormat:
        @"%@/Library/Containers/%@/Data/Library/Application Support/ES-Memory/server.plist",
        NSHomeDirectory(), HOST_BUNDLE_ID];

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info) {
        if (!quiet) {
            fprintf(stderr, "[es-bridge] server.plist not found at %s\n", plistPath.UTF8String);
            fprintf(stderr, "[es-bridge] Is ES Memory MCP running?\n");
        }
        return nil;
    }

    NSString *urlString = info[@"url"];
    if (urlString.length == 0) {
        if (!quiet) fprintf(stderr, "[es-bridge] server.plist missing 'url' key\n");
        return nil;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (!quiet) fprintf(stderr, "[es-bridge] invalid URL in server.plist: %s\n",
                            urlString.UTF8String);
        return nil;
    }

    NSString *version = info[@"version"];
    if (version.length > 0) gServerVersion = version;

    if (!quiet) {
        fprintf(stderr, "[es-bridge] using %s\n", plistPath.UTF8String);
        if (gServerVersion) {
            fprintf(stderr, "[es-bridge] ES Memory v%s\n", gServerVersion.UTF8String);
        }
    }
    return url;
}

/// Try discovery once verbosely; if that misses, poll every 500ms for up to 5s
/// (quiet, so logs aren't spammed). On a polled hit, emit the verbose diagnostic.
static NSURL *DiscoverServerURLWithPolling(void) {
    NSURL *url = DiscoverServerURL(NO);
    if (url) return url;
    fprintf(stderr, "[es-bridge] waiting up to 5s for ES Memory...\n");
    for (int i = 0; i < 10; i++) {
        [NSThread sleepForTimeInterval:0.5];
        url = DiscoverServerURL(YES);
        if (url) {
            (void)DiscoverServerURL(NO); // re-emit the path + version diagnostic
            fprintf(stderr, "[es-bridge] connected after %dms\n", (i + 1) * 500);
            return url;
        }
    }
    return nil;
}

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

        gServerURL = DiscoverServerURLWithPolling();
        if (gServerURL) {
            fprintf(stderr, "[es-bridge] connected to %s\n",
                    gServerURL.absoluteString.UTF8String);
        } else {
            fprintf(stderr, "[es-bridge] entering degraded mode — will respond locally "
                            "with setup help; auto-recovers if ES Memory starts.\n");
        }

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

                // Lazy retry — the host may have just launched.
                if (!gServerURL) {
                    gServerURL = DiscoverServerURL(YES);
                    if (gServerURL) {
                        fprintf(stderr, "[es-bridge] recovered: connected to %s\n",
                                gServerURL.absoluteString.UTF8String);
                    }
                }

                NSString *output = nil;

                if (gServerURL) {
                    NSError *error = nil;
                    NSString *response = ForwardRequest(line, &error);
                    if (response) {
                        output = response;
                    } else if (error) {
                        // Connection failed — host probably went down. Drop the
                        // cached URL so the next request re-attempts discovery,
                        // and respond from the degraded handler for this one.
                        fprintf(stderr, "[es-bridge] forward error: %s — dropping cached URL\n",
                                error.localizedDescription.UTF8String);
                        gServerURL = nil;
                        gServerVersion = nil;
                        NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData
                                                                            options:0 error:nil];
                        if ([msg isKindOfClass:[NSDictionary class]]) {
                            output = DegradedResponseForRequest(msg);
                        }
                    }
                    // response nil + no error → 202 ack, no output needed.
                } else {
                    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData
                                                                        options:0 error:nil];
                    if ([msg isKindOfClass:[NSDictionary class]]) {
                        output = DegradedResponseForRequest(msg);
                    }
                }

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
