//
//  SchemaCache.m
//  ES-Memory-Bridge
//

#import "SchemaCache.h"
#import "Forwarder.h"
#import "MCPFraming.h"
#import <os/lock.h>

static NSString *const kBundleIdentifier = @"com.elarity.es-memory-mcp";
static NSString *const kCacheFileName    = @"tools.json";
static NSString *const kBootstrapResource = @"tools-bootstrap";
static NSString *const kTTLDefaultsKey   = @"ESMBSchemaCacheTTL";
static const NSTimeInterval kDefaultTTL  = 24 * 60 * 60; // 24 hours

@implementation SchemaCache {
    NSArray<NSDictionary *> *_currentTools;
    os_unfair_lock _toolsLock;

    dispatch_queue_t _refreshQueue;
    BOOL _refreshInFlight;
    os_unfair_lock _refreshLock;

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
    _toolsLock = OS_UNFAIR_LOCK_INIT;
    _refreshLock = OS_UNFAIR_LOCK_INIT;
    _refreshQueue = dispatch_queue_create("com.elarity.esmb.schema.refresh", DISPATCH_QUEUE_SERIAL);
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

- (NSArray<NSDictionary *> *)_mergeMemoryCLIInto:(NSArray<NSDictionary *> *)serverTools {
    if (!serverTools) return @[ _memoryCLISchema ];
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

#pragma mark - Disk paths

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

- (BOOL)_writeDiskCache:(NSArray *)tools {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:tools
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) {
        fprintf(stderr, "[es-bridge] schema cache encode failed: %s\n",
                err.localizedDescription.UTF8String);
        return NO;
    }
    NSString *dir = [self _cacheDirectory];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmp = [[self _cacheFilePath] stringByAppendingString:@".tmp"];
    if (![data writeToFile:tmp atomically:NO]) {
        fprintf(stderr, "[es-bridge] schema cache tmp write failed at %s\n",
                tmp.UTF8String);
        return NO;
    }
    if (rename(tmp.UTF8String, [self _cacheFilePath].UTF8String) != 0) {
        fprintf(stderr, "[es-bridge] schema cache rename failed: %s\n", strerror(errno));
        return NO;
    }
    return YES;
}

- (nullable NSArray *)_readBootstrap {
    NSString *path = [[NSBundle mainBundle] pathForResource:kBootstrapResource ofType:@"json"];
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [arr isKindOfClass:NSArray.class] ? arr : nil;
}

#pragma mark - Public API

- (void)loadOnStartupWithFallback:(NSArray<NSDictionary *> *)inMemoryFallback {
    NSArray *loaded = [self _readDiskCache];
    NSString *source = @"disk cache";
    if (!loaded) {
        loaded = [self _readBootstrap];
        if (loaded) source = @"bundle bootstrap";
    }
    if (!loaded && inMemoryFallback) {
        loaded = inMemoryFallback;
        source = @"in-memory fallback";
    }
    if (!loaded) {
        loaded = @[]; // memory_cli will still be merged below
        source = @"empty (no cache, no bootstrap, no fallback)";
    }

    NSArray *merged = [self _mergeMemoryCLIInto:loaded];
    os_unfair_lock_lock(&_toolsLock);
    _currentTools = merged;
    os_unfair_lock_unlock(&_toolsLock);

    fprintf(stderr, "[es-bridge] schema cache loaded from %s (%lu tools)\n",
            source.UTF8String, (unsigned long)merged.count);

    if ([self isStale]) {
        [self refreshAsync];
    }
}

- (NSArray<NSDictionary *> *)currentTools {
    os_unfair_lock_lock(&_toolsLock);
    NSArray *snapshot = _currentTools ?: @[];
    os_unfair_lock_unlock(&_toolsLock);
    return snapshot;
}

- (BOOL)isStale {
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:[self _cacheFilePath] error:nil];
    NSDate *mtime = attrs.fileModificationDate;
    if (!mtime) return YES; // no cache file → stale

    NSTimeInterval ttl = kDefaultTTL;
    NSNumber *override = [[NSUserDefaults standardUserDefaults] objectForKey:kTTLDefaultsKey];
    if ([override isKindOfClass:NSNumber.class]) ttl = override.doubleValue;

    return [[NSDate date] timeIntervalSinceDate:mtime] > ttl;
}

- (void)refreshAsync {
    os_unfair_lock_lock(&_refreshLock);
    BOOL alreadyInFlight = _refreshInFlight;
    _refreshInFlight = YES;
    os_unfair_lock_unlock(&_refreshLock);
    if (alreadyInFlight) return;

    dispatch_async(_refreshQueue, ^{
        static NSInteger refreshId = 90000;
        refreshId++;
        NSString *line = ESMBEncodeJSON(@{
            @"jsonrpc": @"2.0",
            @"id": @(refreshId),
            @"method": @"tools/list",
            @"params": @{}
        });

        NSError *err = nil;
        NSString *response = [[Forwarder shared] forwardLine:line error:&err];
        BOOL success = NO;
        if (response) {
            NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *tools = nil;
            if ([parsed isKindOfClass:NSDictionary.class]) {
                id result = parsed[@"result"];
                if ([result isKindOfClass:NSDictionary.class]) {
                    id t = ((NSDictionary *)result)[@"tools"];
                    if ([t isKindOfClass:NSArray.class]) tools = t;
                }
            }
            if (tools) {
                [self _writeDiskCache:tools];
                NSArray *merged = [self _mergeMemoryCLIInto:tools];
                os_unfair_lock_lock(&_toolsLock);
                _currentTools = merged;
                os_unfair_lock_unlock(&_toolsLock);
                fprintf(stderr, "[es-bridge] schema cache refreshed (%lu tools from server)\n",
                        (unsigned long)merged.count);
                success = YES;
            }
        }
        if (!success) {
            fprintf(stderr, "[es-bridge] schema refresh failed: %s — keeping previous snapshot\n",
                    err.localizedDescription.UTF8String ?: "no response from host");
        }

        os_unfair_lock_lock(&_refreshLock);
        _refreshInFlight = NO;
        os_unfair_lock_unlock(&_refreshLock);
    });
}

@end
