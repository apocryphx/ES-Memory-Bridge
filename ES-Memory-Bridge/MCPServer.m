//
//  MCPServer.m
//  ES-Memory-Bridge
//

#import "MCPServer.h"
#import "MCPFraming.h"
#import "DegradedResponses.h"
#import "Forwarder.h"
#import "SchemaCache.h"
#import "ESBridgeCLI.h"
#import <AppKit/AppKit.h>

@interface MCPServer ()
@property (strong) dispatch_queue_t readQueue;
@property (strong) dispatch_queue_t writeQueue;
@property (strong) dispatch_queue_t workQueue;
@property (strong) NSFileHandle    *stdinHandle;
@property (strong) NSFileHandle    *stdoutHandle;
@property (strong) NSMutableData   *inputBuffer;
@end

@implementation MCPServer

+ (instancetype)shared {
    static MCPServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MCPServer alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _readQueue   = dispatch_queue_create("esmb.mcp.read",  DISPATCH_QUEUE_SERIAL);
    _writeQueue  = dispatch_queue_create("esmb.mcp.write", DISPATCH_QUEUE_SERIAL);
    _workQueue   = dispatch_queue_create("esmb.mcp.work",  DISPATCH_QUEUE_CONCURRENT);
    _stdinHandle  = [NSFileHandle fileHandleWithStandardInput];
    _stdoutHandle = [NSFileHandle fileHandleWithStandardOutput];
    _inputBuffer  = [NSMutableData data];
    return self;
}

- (void)start {
    fprintf(stderr, "[es-bridge] MCP server starting (pid=%d)\n", getpid());

    __weak typeof(self) weak = self;
    self.stdinHandle.readabilityHandler = ^(NSFileHandle *h) {
        __strong typeof(weak) s = weak;
        if (!s) return;

        NSData *chunk = nil;
        @try { chunk = [h availableData]; }
        @catch (NSException *e) {
            fprintf(stderr, "[es-bridge] stdin read exception: %s\n",
                    e.reason.UTF8String ?: "?");
        }

        if (!chunk.length) {
            h.readabilityHandler = nil;
            fprintf(stderr, "[es-bridge] stdin EOF — draining and terminating\n");
            // Drain three queues in order before terminating:
            //   1. readQueue   (serial)     — process any pending input chunks
            //   2. workQueue   (concurrent) — finish handleLine for every
            //                                 line drained in step 1
            //   3. writeQueue  (serial)     — flush every -write: that
            //                                 handleLine dispatched
            // Then hop to the main thread for NSApp.terminate. Without
            // step 1, the barrier on workQueue can fire before late
            // chunks have even been pushed onto workQueue, and a tool
            // response gets lost in the shutdown race.
            dispatch_async(s.readQueue, ^{
                dispatch_barrier_async(s.workQueue, ^{
                    dispatch_async(s.writeQueue, ^{
                        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
                    });
                });
            });
            return;
        }

        dispatch_async(s.readQueue, ^{
            [s.inputBuffer appendData:chunk];
            [s drainLines];
        });
    };
}

- (void)drainLines {
    static const uint8_t nl = '\n';
    while (YES) {
        NSRange r = [self.inputBuffer rangeOfData:[NSData dataWithBytes:&nl length:1]
                                          options:0
                                            range:NSMakeRange(0, self.inputBuffer.length)];
        if (r.location == NSNotFound) break;

        NSData *lineData = [self.inputBuffer subdataWithRange:NSMakeRange(0, r.location)];
        [self.inputBuffer replaceBytesInRange:NSMakeRange(0, r.location + 1)
                                    withBytes:NULL length:0];
        if (!lineData.length) continue;

        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length) dispatch_async(self.workQueue, ^{ [self handleLine:line]; });
    }
}

- (void)write:(NSString *_Nullable)line {
    if (!line) return;
    dispatch_async(self.writeQueue, ^{
        NSData *out = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        @try { [self.stdoutHandle writeData:out]; }
        @catch (NSException *e) {
            fprintf(stderr, "[es-bridge] stdout write failed: %s\n",
                    e.reason.UTF8String ?: "?");
        }
    });
}

#pragma mark - Line dispatch

- (void)handleLine:(NSString *)line {
    NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];

    NSString *output = nil;

    if ([msg isKindOfClass:[NSDictionary class]]) {
        NSString *method = msg[@"method"];
        id rpcId = msg[@"id"];

        if ([method isEqualToString:@"tools/list"]) {
            // Serve from SchemaCache (disk cache + memory_cli merge + async
            // refresh from server). The bridge IS the curated surface — we
            // never forward tools/list.
            output = ESMBJSONRPCResult(rpcId, @{ @"tools": [[SchemaCache shared] currentTools] });
        } else if ([method isEqualToString:@"tools/call"]) {
            NSString *toolName = msg[@"params"][@"name"];

            // Pre-normalize relative-date args ("+30 days") into ISO-8601
            // before forwarding. If normalization fails, error locally
            // instead of forwarding garbage.
            NSArray<NSString *> *dateKeys = nil;
            if ([toolName isEqualToString:@"memory_create_tag"])      dateKeys = @[ @"expiresAt" ];
            else if ([toolName isEqualToString:@"memory_extend_tag"]) dateKeys = @[ @"newExpiresAt" ];
            else if ([toolName isEqualToString:@"memory_store"])      dateKeys = @[ @"dateCreated" ];
            else if ([toolName isEqualToString:@"memory_update"])     dateKeys = @[ @"dateCreated" ];

            BOOL dateNormFailed = NO;
            NSMutableDictionary *normalizedArgs = nil;
            for (NSString *dateKey in dateKeys) {
                id raw = msg[@"params"][@"arguments"][dateKey];
                if (![raw isKindOfClass:NSString.class] || [(NSString *)raw length] == 0) continue;
                NSString *normalized = ESBridgeNormalizeRelativeDate(raw);
                if (!normalized) {
                    output = ESMBJSONRPCError(rpcId, -32602,
                        [NSString stringWithFormat:
                            @"%@: '%@' is not a valid date. "
                             "Pass ISO-8601 (e.g. 2026-06-01T12:00:00Z) or a relative "
                             "offset like \"+30 days\", \"-1 hour\", \"+2h\".",
                            dateKey, raw]);
                    dateNormFailed = YES;
                    break;
                }
                if (![raw isEqualToString:normalized]) {
                    if (!normalizedArgs) {
                        normalizedArgs = [msg[@"params"][@"arguments"] mutableCopy]
                            ?: [NSMutableDictionary dictionary];
                    }
                    normalizedArgs[dateKey] = normalized;
                }
            }
            if (!dateNormFailed && normalizedArgs) {
                NSMutableDictionary *newParams = [msg[@"params"] mutableCopy];
                newParams[@"arguments"] = normalizedArgs;
                NSMutableDictionary *newMsg = [msg mutableCopy];
                newMsg[@"params"] = newParams;
                NSData *encoded = [NSJSONSerialization
                    dataWithJSONObject:newMsg options:0 error:nil];
                if (encoded) {
                    line = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
                    msg  = newMsg;
                }
            }

            if (!dateNormFailed && [toolName isEqualToString:@"memory_cli"]) {
                // Bridge-local handling. The CLI executor makes its own
                // HTTP calls via ForwardRequest for each pipeline stage.
                NSString *expression = msg[@"params"][@"arguments"][@"expression"];
                if (![expression isKindOfClass:[NSString class]] || expression.length == 0) {
                    output = ESMBJSONRPCError(rpcId, -32602,
                        @"`expression` is required. Try memory_cli(\"man\") to see commands.");
                } else {
                    NSError *parseErr = nil;
                    NSArray *tokens = ESBridgeCLITokenize(expression, &parseErr);
                    NSDictionary *result = nil;
                    if (!tokens) {
                        result = @{
                            @"error":      @"parse_error",
                            @"message":    parseErr.localizedDescription ?: @"could not tokenize",
                            @"expression": expression,
                        };
                    } else {
                        NSArray *stages = ESBridgeCLIParseStages(tokens, &parseErr);
                        if (!stages) {
                            result = @{
                                @"error":      @"parse_error",
                                @"message":    parseErr.localizedDescription ?: @"could not parse",
                                @"expression": expression,
                            };
                        } else {
                            result = ESBridgeCLIExecute(stages);
                        }
                    }
                    NSData *resultData = [NSJSONSerialization
                        dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
                    NSString *resultText = resultData
                        ? [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding]
                        : @"{}";
                    output = ESMBJSONRPCResult(rpcId, @{
                        @"content": @[ @{ @"type": @"text", @"text": resultText } ]
                    });
                }
            }
        }
    }

    // Fall through to forwarding for anything we didn't handle.
    if (!output) {
        // Synchronous forward on the concurrent work queue. Multiple
        // inbound lines run on parallel worker threads, each doing its
        // own sync forward — so this is still parallel under load.
        //
        // We deliberately don't use forwardLineAsync: here: stdin EOF
        // triggers [NSApp terminate] immediately, which would lose any
        // pending async responses. Sync ensures handleLine completes
        // (and writes its response) before EOF can race it.
        NSError *error = nil;
        NSString *response = ForwardRequest(line, &error);
        if (response) {
            output = response;
        } else if (error && [msg isKindOfClass:[NSDictionary class]]) {
            output = ESMBDegradedResponseForRequest(msg, [[SchemaCache shared] currentTools]);
        }
        // response nil + no error → 202 ack from host, no output.
        // Reachability transitions are logged inside Forwarder.
    }

    if (output) [self write:output];
}

@end
