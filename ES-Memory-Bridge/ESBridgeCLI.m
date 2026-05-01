//
//  ESBridgeCLI.m
//  ES-Memory-Bridge
//

#import "ESBridgeCLI.h"
#import "ESBridgeCLICommands.h"

#pragma mark - ESBridgeCLIToken

@implementation ESBridgeCLIToken {
    NSString *_value;
    BOOL _isPipe;
    BOOL _wasQuoted;
}

- (instancetype)initWithValue:(NSString *)value pipe:(BOOL)isPipe quoted:(BOOL)wasQuoted {
    self = [super init];
    if (self) {
        _value = [value copy];
        _isPipe = isPipe;
        _wasQuoted = wasQuoted;
    }
    return self;
}

- (NSString *)value     { return _value; }
- (BOOL)isPipe          { return _isPipe; }
- (BOOL)wasQuoted       { return _wasQuoted; }

- (NSString *)description {
    if (_isPipe) return @"|";
    return _wasQuoted ? [NSString stringWithFormat:@"\"%@\"", _value] : _value;
}

@end

#pragma mark - Tokenizer

// Shell-style tokenizer. Three states:
//   - default: read bare words, treat `|` as a separator, treat `"` and `'` as quote-open
//   - in_double_quote: read until matching `"`, honor `\"` and `\\` escapes
//   - in_single_quote: read literally until matching `'`, no escapes (Bourne shell)
// Whitespace separates tokens outside quotes; preserved inside.
NSArray<ESBridgeCLIToken *> * _Nullable
ESBridgeCLITokenize(NSString *expression, NSError * _Nullable * _Nullable errorOut) {
    if (!expression) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"empty expression"}];
        }
        return nil;
    }

    NSMutableArray<ESBridgeCLIToken *> *tokens = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    BOOL hasContent = NO;
    BOOL wasQuoted = NO;
    enum { kDefault, kInDouble, kInSingle } state = kDefault;

    NSUInteger i = 0;
    NSUInteger len = expression.length;

    while (i < len) {
        unichar c = [expression characterAtIndex:i];

        if (state == kDefault) {
            if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) {
                if (hasContent) {
                    [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
                    [current setString:@""];
                    hasContent = NO;
                    wasQuoted = NO;
                }
                i++;
                continue;
            }
            if (c == '|') {
                if (hasContent) {
                    [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
                    [current setString:@""];
                    hasContent = NO;
                    wasQuoted = NO;
                }
                [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:@"|" pipe:YES quoted:NO]];
                i++;
                continue;
            }
            if (c == '"') {
                state = kInDouble;
                wasQuoted = YES;
                hasContent = YES;
                i++;
                continue;
            }
            if (c == '\'') {
                state = kInSingle;
                wasQuoted = YES;
                hasContent = YES;
                i++;
                continue;
            }
            [current appendFormat:@"%C", c];
            hasContent = YES;
            i++;
            continue;
        }

        if (state == kInDouble) {
            if (c == '\\' && i + 1 < len) {
                unichar next = [expression characterAtIndex:i + 1];
                if (next == '"' || next == '\\') {
                    [current appendFormat:@"%C", next];
                    i += 2;
                    continue;
                }
            }
            if (c == '"') {
                state = kDefault;
                i++;
                continue;
            }
            [current appendFormat:@"%C", c];
            i++;
            continue;
        }

        if (state == kInSingle) {
            if (c == '\'') {
                state = kDefault;
                i++;
                continue;
            }
            [current appendFormat:@"%C", c];
            i++;
            continue;
        }
    }

    if (state != kDefault) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:2
                                         userInfo:@{NSLocalizedDescriptionKey:
                                            (state == kInDouble ? @"unterminated double quote"
                                                                : @"unterminated single quote")}];
        }
        return nil;
    }

    if (hasContent) {
        [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
    }
    return tokens;
}

#pragma mark - ESBridgeCLIStage

@implementation ESBridgeCLIStage {
    NSString *_name;
    NSArray<NSString *> *_positional;
    NSDictionary<NSString *, id> *_flags;
}

- (instancetype)initWithName:(NSString *)name
                   positional:(NSArray<NSString *> *)positional
                        flags:(NSDictionary<NSString *, id> *)flags {
    self = [super init];
    if (self) {
        _name = [name copy];
        _positional = [positional copy];
        _flags = [flags copy];
    }
    return self;
}

- (NSString *)name                              { return _name; }
- (NSArray<NSString *> *)positional             { return _positional; }
- (NSDictionary<NSString *, id> *)flags         { return _flags; }

- (NSString *)description {
    NSMutableString *s = [NSMutableString stringWithString:_name];
    for (NSString *p in _positional) {
        if ([p rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
            [s appendFormat:@" \"%@\"", p];
        } else {
            [s appendFormat:@" %@", p];
        }
    }
    [_flags enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        if ([v isKindOfClass:NSNumber.class] && [v boolValue]) {
            [s appendFormat:@" --%@", k];
        } else {
            NSString *vs = [NSString stringWithFormat:@"%@", v];
            if ([vs rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
                [s appendFormat:@" --%@ \"%@\"", k, vs];
            } else {
                [s appendFormat:@" --%@ %@", k, vs];
            }
        }
    }];
    return s;
}

@end

#pragma mark - Parser

NSArray<ESBridgeCLIStage *> * _Nullable
ESBridgeCLIParseStages(NSArray<ESBridgeCLIToken *> *tokens,
                       NSError * _Nullable * _Nullable errorOut) {
    NSMutableArray<ESBridgeCLIStage *> *stages = [NSMutableArray array];
    NSUInteger i = 0;
    NSUInteger n = tokens.count;

    if (n == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"empty pipeline"}];
        }
        return nil;
    }

    while (i < n) {
        if (tokens[i].isPipe) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:4
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                @"empty stage (pipe with nothing on the left)"}];
            }
            return nil;
        }

        ESBridgeCLIToken *nameTok = tokens[i++];
        NSString *name = nameTok.value;
        if ([name hasPrefix:@"--"]) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:5
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"expected command name, got flag %@", name]}];
            }
            return nil;
        }

        NSMutableArray<NSString *> *positional = [NSMutableArray array];
        NSMutableDictionary<NSString *, id> *flags = [NSMutableDictionary dictionary];

        while (i < n && !tokens[i].isPipe) {
            ESBridgeCLIToken *tok = tokens[i];
            if (!tok.wasQuoted && [tok.value hasPrefix:@"--"]) {
                NSString *flagName = [tok.value substringFromIndex:2];
                if (flagName.length == 0) {
                    if (errorOut) {
                        *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:6
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                                        @"empty flag name (--)"}];
                    }
                    return nil;
                }
                i++;
                if (i >= n || tokens[i].isPipe ||
                    (!tokens[i].wasQuoted && [tokens[i].value hasPrefix:@"--"])) {
                    flags[flagName] = @YES;
                    continue;
                }
                flags[flagName] = tokens[i].value;
                i++;
                continue;
            }
            [positional addObject:tok.value];
            i++;
        }

        [stages addObject:[[ESBridgeCLIStage alloc] initWithName:name positional:positional flags:flags]];

        if (i < n && tokens[i].isPipe) i++;
    }

    return stages;
}

#pragma mark - Server tool calls

NSDictionary * _Nullable
ESBridgeCallTool(NSString *toolName,
                 NSDictionary *arguments,
                 NSError * _Nullable * _Nullable errorOut) {
    static NSInteger nextId = 1000;
    NSInteger thisId = ++nextId;

    NSDictionary *envelope = @{
        @"jsonrpc": @"2.0",
        @"id":      @(thisId),
        @"method":  @"tools/call",
        @"params":  @{
            @"name":      toolName,
            @"arguments": arguments ?: @{}
        }
    };

    NSData *envelopeData = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    if (!envelopeData) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:10
                                         userInfo:@{NSLocalizedDescriptionKey: @"could not encode JSON-RPC envelope"}];
        }
        return nil;
    }

    NSString *envelopeStr = [[NSString alloc] initWithData:envelopeData encoding:NSUTF8StringEncoding];
    NSError *forwardErr = nil;
    NSString *responseStr = ForwardRequest(envelopeStr, &forwardErr);
    if (!responseStr) {
        if (errorOut) {
            *errorOut = forwardErr ?: [NSError errorWithDomain:@"ESBridgeCLIError" code:11
                                                       userInfo:@{NSLocalizedDescriptionKey: @"no response from host"}];
        }
        return nil;
    }

    NSData *responseData = [responseStr dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *responseDict = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    if (![responseDict isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:12
                                         userInfo:@{NSLocalizedDescriptionKey: @"malformed JSON response"}];
        }
        return nil;
    }

    // Surface MCP-level errors to the caller.
    NSDictionary *mcpError = responseDict[@"error"];
    if ([mcpError isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            NSString *msg = mcpError[@"message"] ?: @"server error";
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIServerError" code:13
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }

    NSDictionary *result = responseDict[@"result"];
    if (![result isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:14
                                         userInfo:@{NSLocalizedDescriptionKey: @"missing result in response"}];
        }
        return nil;
    }

    NSArray *content = result[@"content"];
    if (![content isKindOfClass:NSArray.class] || content.count == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:15
                                         userInfo:@{NSLocalizedDescriptionKey: @"empty content array"}];
        }
        return nil;
    }

    NSDictionary *first = content[0];
    NSString *text = first[@"text"];
    if (![text isKindOfClass:NSString.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:16
                                         userInfo:@{NSLocalizedDescriptionKey: @"missing text in content"}];
        }
        return nil;
    }

    NSData *innerData = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *inner = [NSJSONSerialization JSONObjectWithData:innerData options:0 error:nil];
    if (![inner isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:17
                                         userInfo:@{NSLocalizedDescriptionKey: @"inner result is not a dict"}];
        }
        return nil;
    }

    return inner;
}

#pragma mark - Execution

NSDictionary *
ESBridgeCLIExecute(NSArray<ESBridgeCLIStage *> *stages) {
    if (stages.count == 0) {
        return @{
            @"error":   @"empty_pipeline",
            @"message": @"No commands. Try 'man' to see what's available.",
        };
    }

    // Short-circuit: man as the only command.
    ESBridgeCLIStage *first = stages.firstObject;
    if ([first.name isEqualToString:@"man"]) {
        if (stages.count > 1) {
            return @{
                @"error":   @"man_must_be_terminal",
                @"message": @"`man` doesn't compose; run it on its own.",
            };
        }
        NSString *target = first.positional.firstObject;
        return ESBridgeCLIRunMan(target);
    }

    // Pipeline state. Population flows between stages as memory dicts.
    // `pendingTags` and `pendingDays` are accumulated by lfind stages and
    // consumed by the next fetcher stage (w2vgrep, grep, etc). If a pipeline
    // ends without any fetcher consuming them, we flush them as a memory_tagged
    // or memory_recent call.
    NSMutableArray<NSString *> *diagLines = [NSMutableArray arrayWithCapacity:stages.count];
    NSArray<NSDictionary *> *prior = nil;
    NSArray<NSString *> *pendingTags = nil;
    NSNumber *pendingDays = nil;
    BOOL anyFetcherFired = NO;

    for (NSUInteger idx = 0; idx < stages.count; idx++) {
        ESBridgeCLIStage *stage = stages[idx];
        BOOL isFirst = (idx == 0);
        BOOL isLast = (idx == stages.count - 1);

        // Terminals: cat, wc.
        if ([stage.name isEqualToString:@"cat"] ||
            [stage.name isEqualToString:@"wc"]) {
            // If lfind accumulated filters but no fetcher fired, flush now.
            if (!anyFetcherFired && (pendingTags || pendingDays)) {
                ESBridgeCLIStageResult flush =
                    ESBridgeCLIFlushPendingFilters(pendingTags, pendingDays, isFirst);
                if (flush.error) {
                    return @{
                        @"error":    flush.error,
                        @"message":  flush.errorMessage ?: @"",
                        @"pipeline": [diagLines componentsJoinedByString:@"\n"],
                    };
                }
                prior = flush.population;
                pendingTags = nil;
                pendingDays = nil;
                anyFetcherFired = YES;
                // Note: flush has no diag line — the lfind stage already emitted one
            }

            ESBridgeCLIStageResult result = ESBridgeCLIRunTerminal(stage, prior, isFirst);
            [diagLines addObject:result.diagLine];
            NSMutableDictionary *response = [result.response mutableCopy] ?: [NSMutableDictionary dictionary];
            response[@"pipeline"] = [diagLines componentsJoinedByString:@"\n"];
            return response;
        }

        ESBridgeCLIStageResult result =
            ESBridgeCLIRunPopulationStage(stage, prior, pendingTags, pendingDays, isFirst);
        [diagLines addObject:result.diagLine];

        if (result.error) {
            return @{
                @"error":    result.error,
                @"message":  result.errorMessage ?: @"",
                @"pipeline": [diagLines componentsJoinedByString:@"\n"],
            };
        }

        // Update pending filters (lfind sets them, fetchers clear them).
        pendingTags = result.outPendingTags;
        pendingDays = result.outPendingDays;
        if (!result.deferred) {
            prior = result.population;
            anyFetcherFired = YES;
        }

        if (isLast) {
            // If we ended on a deferred lfind, flush it now.
            if (!anyFetcherFired && (pendingTags || pendingDays)) {
                ESBridgeCLIStageResult flush =
                    ESBridgeCLIFlushPendingFilters(pendingTags, pendingDays, NO);
                if (flush.error) {
                    return @{
                        @"error":    flush.error,
                        @"message":  flush.errorMessage ?: @"",
                        @"pipeline": [diagLines componentsJoinedByString:@"\n"],
                    };
                }
                prior = flush.population;
            }

            return @{
                @"pipeline": [diagLines componentsJoinedByString:@"\n"],
                @"results":  prior ?: @[],
                @"count":    @(prior.count),
            };
        }
    }

    return @{
        @"pipeline": [diagLines componentsJoinedByString:@"\n"],
        @"results":  @[],
        @"count":    @0,
    };
}
