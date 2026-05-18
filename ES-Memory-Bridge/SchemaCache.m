//
//  SchemaCache.m
//  ES-Memory-Bridge
//

#import "SchemaCache.h"
#import "Forwarder.h"
#import "MCPFraming.h"

static NSString *const kBundleIdentifier = @"com.elarity.es-memory-mcp";
static NSString *const kCacheFileName    = @"tools.json";

@implementation SchemaCache {
    NSDictionary *_memoryCLISchema;
}

+ (instancetype)shared {
    static SchemaCache *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[SchemaCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _memoryCLISchema = [self.class memoryCLISchema];
    return self;
}

#pragma mark - memory_cli bridge-local schema

+ (NSDictionary *)memoryCLISchema {
    static NSDictionary *schema = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        schema = @{
            @"name": @"memory_cli",
            @"description":
                @"Unix-pipeline-style surface for ES Memory. Compose retrieval and "
                 "curatorial operations with `|` exactly the way you would in a shell.\n\n"
                 "Start with `man` to see the full command vocabulary, then `man <command>` "
                 "for any specific command. The system documents itself.\n\n"
                 "Quick examples:\n"
                 "  memory_cli(\"man\")\n"
                 "  memory_cli(\"lfind --tag 'Isolde' | head 5\")\n"
                 "  memory_cli(\"lfind --tag-kind project | wc\")\n"
                 "  memory_cli(\"discover --mode forgotten | w2vgrep 'continuity' | head 10\")\n"
                 "  memory_cli(\"grep Isolde | grep Myth | tag 'Isoldes Stories'\")  // curatorial\n\n"
                 "Most stages read; `tag` and `untag` write (atomic per pipeline). If "
                 "results disappoint, vary the pipeline: reorder stages, replace one "
                 "command with another at the same position, or change a parameter and "
                 "re-run. Be persistent. Be creative. You will find it eventually.",
            @"annotations": @{ @"readOnlyHint": @NO, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"expression": @{
                        @"type": @"string",
                        @"description": @"A pipeline expression. Run memory_cli(\"man\") to list commands."
                    }
                },
                @"required": @[ @"expression" ]
            }
        };
    });
    return schema;
}

- (NSArray<NSDictionary *> *)_mergeMemoryCLIInto:(nullable NSArray<NSDictionary *> *)serverTools {
    if (!serverTools.count) return @[ _memoryCLISchema ];
    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:serverTools.count + 1];
    [merged addObject:_memoryCLISchema];
    for (NSDictionary *t in serverTools) {
        if ([t isKindOfClass:NSDictionary.class] &&
            ![t[@"name"] isEqual:@"memory_cli"]) {
            [merged addObject:t];
        }
    }
    return [merged copy];
}

#pragma mark - Disk last-known-good

- (NSString *)_cacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:kBundleIdentifier];
}

- (NSString *)_cacheFilePath {
    return [[self _cacheDirectory] stringByAppendingPathComponent:kCacheFileName];
}

- (nullable NSArray *)_readDiskCache {
    NSData *data = [NSData dataWithContentsOfFile:[self _cacheFilePath]];
    if (!data) return nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [arr isKindOfClass:NSArray.class] ? arr : nil;
}

- (void)_writeDiskCache:(NSArray *)tools {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:tools
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) {
        fprintf(stderr, "[es-bridge] last-known-good encode failed: %s\n",
                err.localizedDescription.UTF8String);
        return;
    }
    NSString *dir = [self _cacheDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmp = [[self _cacheFilePath] stringByAppendingString:@".tmp"];
    if (![data writeToFile:tmp atomically:NO]) {
        fprintf(stderr, "[es-bridge] last-known-good tmp write failed at %s\n",
                tmp.UTF8String);
        return;
    }
    if (rename(tmp.UTF8String, [self _cacheFilePath].UTF8String) != 0) {
        fprintf(stderr, "[es-bridge] last-known-good rename failed: %s\n", strerror(errno));
    }
}

#pragma mark - Public API

- (NSArray<NSDictionary *> *)currentTools {
    // Fast path: if Forwarder already knows the host is unreachable
    // from a recent failed forward, skip the redundant 120s timeout
    // and go straight to the last-known-good disk file. Forwarder
    // flips reachability back to YES the moment any forward succeeds
    // (e.g. a subsequent tool call once the user starts the server),
    // so the next currentTools call will live-fetch again.
    if (![[Forwarder shared] hostReachable]) {
        return [self _serveLastKnownGoodOrCLIOnly];
    }

    // Per-call id counter — purely for log readability. Concurrent
    // tools/list is rare and a collision here is harmless.
    static NSInteger toolsListId = 80000;
    toolsListId++;

    NSString *line = ESMBEncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": @(toolsListId),
        @"method": @"tools/list",
        @"params": @{}
    });

    NSError *err = nil;
    NSString *response = [[Forwarder shared] forwardLine:line error:&err];

    NSArray *tools = nil;
    if (response) {
        NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:NSDictionary.class]) {
            id result = parsed[@"result"];
            if ([result isKindOfClass:NSDictionary.class]) {
                id t = ((NSDictionary *)result)[@"tools"];
                if ([t isKindOfClass:NSArray.class]) tools = t;
            }
        }
    }

    if (tools) {
        // Live success — persist as last-known-good, then return merged.
        [self _writeDiskCache:tools];
        return [self _mergeMemoryCLIInto:tools];
    }

    // Live failed — Forwarder has flipped hostReachable to NO and logged
    // the transition. Serve last-known-good so Claude has a tool list
    // while the user starts the server; the next tool call will surface
    // the offline error via DegradedResponses.
    return [self _serveLastKnownGoodOrCLIOnly];
}

- (NSArray<NSDictionary *> *)_serveLastKnownGoodOrCLIOnly {
    NSArray *fallback = [self _readDiskCache];
    if (fallback.count) {
        return [self _mergeMemoryCLIInto:fallback];
    }
    return @[ _memoryCLISchema ];
}

@end
