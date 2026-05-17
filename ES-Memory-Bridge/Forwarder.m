//
//  Forwarder.m
//  ES-Memory-Bridge
//

#import "Forwarder.h"
#import <os/lock.h>

static NSString *const kServerURL = @"http://localhost:59123/mcp";

@implementation Forwarder {
    NSURL *_serverURL;
    os_unfair_lock _reachableLock;
    BOOL _hostReachable;
}

+ (instancetype)shared {
    static Forwarder *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[Forwarder alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _serverURL = [NSURL URLWithString:kServerURL];
    _reachableLock = OS_UNFAIR_LOCK_INIT;
    _hostReachable = YES; // optimism; flipped on first failure
    fprintf(stderr, "[es-bridge] forwarding to %s (static URL, no discovery)\n",
            kServerURL.UTF8String);
    return self;
}

- (BOOL)hostReachable {
    os_unfair_lock_lock(&_reachableLock);
    BOOL r = _hostReachable;
    os_unfair_lock_unlock(&_reachableLock);
    return r;
}

- (void)_recordSuccess {
    os_unfair_lock_lock(&_reachableLock);
    BOOL wasUnreachable = !_hostReachable;
    _hostReachable = YES;
    os_unfair_lock_unlock(&_reachableLock);
    if (wasUnreachable) {
        fprintf(stderr, "[es-bridge] host recovered — resuming forwarding\n");
    }
}

- (void)_recordFailureWithError:(NSError *)error {
    os_unfair_lock_lock(&_reachableLock);
    BOOL wasReachable = _hostReachable;
    _hostReachable = NO;
    os_unfair_lock_unlock(&_reachableLock);
    if (wasReachable) {
        fprintf(stderr, "[es-bridge] host unreachable: %s — degraded mode\n",
                error.localizedDescription.UTF8String);
    }
}

- (NSMutableURLRequest *)_requestForLine:(NSString *)jsonLine {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_serverURL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [jsonLine dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json, text/event-stream" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 120.0; // MCP tool calls can be slow
    return request;
}

- (nullable NSString *)forwardLine:(NSString *)jsonLine error:(NSError **)outError {
    NSMutableURLRequest *request = [self _requestForLine:jsonLine];

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

    if (requestError) {
        [self _recordFailureWithError:requestError];
    } else if (responseBody) {
        [self _recordSuccess];
    }
    // responseBody nil + no error = 202 ack; don't flip reachability.

    if (outError) *outError = requestError;
    return responseBody;
}

- (void)forwardLineAsync:(NSString *)jsonLine
              completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    NSMutableURLRequest *request = [self _requestForLine:jsonLine];

    __weak typeof(self) weak = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *responseBody = nil;
        if (!error && data) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status == 200) {
                responseBody = [[NSString alloc] initWithData:data
                                                     encoding:NSUTF8StringEncoding];
            }
        }
        __strong typeof(weak) s = weak;
        if (s) {
            if (error) [s _recordFailureWithError:error];
            else if (responseBody) [s _recordSuccess];
        }
        if (completion) completion(responseBody, error);
    }];
    [task resume];
}

@end

NSString * _Nullable ForwardRequest(NSString *jsonLine, NSError * _Nullable * _Nullable outError) {
    return [[Forwarder shared] forwardLine:jsonLine error:outError];
}
