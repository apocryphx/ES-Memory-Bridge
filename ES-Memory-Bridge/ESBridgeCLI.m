//
//  ESBridgeCLI.m
//  ES-Memory-Bridge
//

#import "ESBridgeCLI.h"

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
            NSString *msg = (state == kInDouble)
                ? @"unterminated double quote"
                // Bourne-shell single quotes are literal — they don't accept
                // any escape, so titles containing apostrophes (e.g.
                // "Claude's Notes") must use double quotes. Tell the user.
                : @"unterminated single quote — single quotes don't allow embedded apostrophes; "
                  @"for titles like Claude's Notes, use double quotes: cat \"Claude's Notes\"";
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:2
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
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

// Strip "uuid" fields from any results array in the response. The bridge↔
// server protocol carries UUIDs (for graph analysis tools, scripts, etc),
// but Claude shouldn't see them — UUIDs are machine identity, titles are
// reading interface. Mixing them in the same response degrades the
// LLM-facing surface for an audience that doesn't need machine identity.
static NSDictionary *StripUUIDsFromResponse(NSDictionary *response) {
    if (![response isKindOfClass:NSDictionary.class]) return response;
    NSArray *results = response[@"results"];
    if (![results isKindOfClass:NSArray.class]) return response;

    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:results.count];
    for (NSDictionary *row in results) {
        if (![row isKindOfClass:NSDictionary.class]) {
            [cleaned addObject:row];
            continue;
        }
        if (row[@"uuid"]) {
            NSMutableDictionary *copy = [row mutableCopy];
            [copy removeObjectForKey:@"uuid"];
            [cleaned addObject:[copy copy]];
        } else {
            [cleaned addObject:row];
        }
    }
    NSMutableDictionary *out = [response mutableCopy];
    out[@"results"] = cleaned;
    return [out copy];
}

NSDictionary *
ESBridgeCLIExecute(NSArray<ESBridgeCLIStage *> *stages) {
    if (stages.count == 0) {
        return @{
            @"error":   @"empty_pipeline",
            @"message": @"No commands. Try 'man' to see what's available.",
        };
    }

    // Marshal each stage to a {name, positional, flags} dict. The server's
    // memory_pipeline tool deserializes this and instantiates the matching
    // ESPipelineFilter classes.
    NSMutableArray<NSDictionary *> *stageDicts = [NSMutableArray arrayWithCapacity:stages.count];
    for (ESBridgeCLIStage *stage in stages) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"name"] = stage.name;
        if (stage.positional.count > 0) d[@"positional"] = stage.positional;
        if (stage.flags.count > 0)      d[@"flags"]      = stage.flags;
        [stageDicts addObject:d];
    }

    NSError *err = nil;
    NSDictionary *response = ESBridgeCallTool(@"memory_pipeline",
                                              @{@"stages": stageDicts},
                                              &err);
    if (!response) {
        return @{
            @"error":   @"server_call_failed",
            @"message": err.localizedDescription ?: @"memory_pipeline call failed",
        };
    }

    return StripUUIDsFromResponse(response);
}
