//
//  main.m
//  ES-Memory-Bridge
//
//  Stdio↔HTTP bridge for the ES Memory MCP server.
//
//  Claude Desktop launches this CLT (packaged inside an .mcpb bundle) as a
//  subprocess. It reads JSON-RPC messages from stdin, forwards each to the
//  host app's HTTP server, and writes the response to stdout.
//
//  Discovery: the bridge shares its CFBundleIdentifier with the host app
//  ("com.elarity.es-memory-mcp"). It reads its own bundle ID at runtime, then
//  reads server.plist from the host's sandbox container at
//      ~/Library/Containers/<id>/Data/Library/Application Support/ES-Memory/server.plist
//

#import <Foundation/Foundation.h>
#include <signal.h>

static NSURL *gServerURL = nil;

#pragma mark - Server Discovery

static NSURL *DiscoverServerURL(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID.length == 0) {
        fprintf(stderr, "[es-bridge] no embedded CFBundleIdentifier; "
                        "build with CREATE_INFOPLIST_SECTION_IN_BINARY=YES\n");
        return nil;
    }

    NSString *plistPath = [NSString stringWithFormat:
        @"%@/Library/Containers/%@/Data/Library/Application Support/ES-Memory/server.plist",
        NSHomeDirectory(), bundleID];

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info) {
        fprintf(stderr, "[es-bridge] server.plist not found at %s\n",
                plistPath.UTF8String);
        fprintf(stderr, "[es-bridge] Is ES Memory MCP running?\n");
        return nil;
    }
    fprintf(stderr, "[es-bridge] using %s\n", plistPath.UTF8String);

    NSString *urlString = info[@"url"];
    if (urlString.length == 0) {
        fprintf(stderr, "[es-bridge] server.plist missing 'url' key\n");
        return nil;
    }

    // GCDWebServer's serverURL is the base (http://localhost:NNNN/) — append /mcp.
    if (![urlString hasSuffix:@"/mcp"] && ![urlString hasSuffix:@"/mcp/"]) {
        urlString = [urlString hasSuffix:@"/"]
            ? [urlString stringByAppendingString:@"mcp"]
            : [urlString stringByAppendingString:@"/mcp"];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        fprintf(stderr, "[es-bridge] invalid URL in server.plist: %s\n",
                urlString.UTF8String);
    }
    return url;
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

#pragma mark - JSON-RPC Error Helper

static NSString *JSONRPCError(id rpcId, NSInteger code, NSString *message) {
    NSDictionary *err = @{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"error": @{ @"code": @(code), @"message": message ?: @"Error" }
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:err options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        gServerURL = DiscoverServerURL();
        if (!gServerURL) return 1;
        fprintf(stderr, "[es-bridge] connected to %s\n",
                gServerURL.absoluteString.UTF8String);

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

                if (response) {
                    NSString *output = [response stringByAppendingString:@"\n"];
                    [stdoutHandle writeData:
                        [output dataUsingEncoding:NSUTF8StringEncoding]];
                } else if (error) {
                    id rpcId = nil;
                    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData
                                                                        options:0 error:nil];
                    if ([msg isKindOfClass:[NSDictionary class]]) rpcId = msg[@"id"];
                    if (rpcId) {
                        NSString *errResp = JSONRPCError(rpcId, -32000,
                            [NSString stringWithFormat:@"ES Memory: %@",
                             error.localizedDescription]);
                        if (errResp) {
                            [stdoutHandle writeData:[[errResp stringByAppendingString:@"\n"]
                                dataUsingEncoding:NSUTF8StringEncoding]];
                        }
                    }
                    fprintf(stderr, "[es-bridge] error: %s\n",
                            error.localizedDescription.UTF8String);
                }
                // response nil + no error → 202 ack, no output needed.
            }
        }

        fprintf(stderr, "[es-bridge] stdin closed, exiting\n");
    }
    return 0;
}
