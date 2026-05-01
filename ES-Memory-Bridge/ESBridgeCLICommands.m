//
//  ESBridgeCLICommands.m
//  ES-Memory-Bridge
//

#import "ESBridgeCLICommands.h"

#pragma mark - Diagnostic line helper

static const NSUInteger kDiagPadWidth = 40;

static NSString *DiagPad(NSString *s) {
    if (s.length >= kDiagPadWidth) return [s stringByAppendingString:@" "];
    NSMutableString *padded = [s mutableCopy];
    while (padded.length < kDiagPadWidth) [padded appendString:@" "];
    return padded;
}

typedef NS_ENUM(NSInteger, ESBridgeCLIStageKind) {
    ESBridgeCLIStageKindFilter,     // grep, discover — selectivity meaningful
    ESBridgeCLIStageKindRanker,     // w2vgrep — re-ranks
    ESBridgeCLIStageKindReorder,    // sort — count never changes
    ESBridgeCLIStageKindSlice,      // head, tail — mechanical
    ESBridgeCLIStageKindCounter,    // wc — just reports
    ESBridgeCLIStageKindReader,     // cat — terminal
    ESBridgeCLIStageKindLfind,      // lfind — usually deferred (no diag annotation)
    ESBridgeCLIStageKindUnknown,
};

static ESBridgeCLIStageKind KindForName(NSString *name) {
    if ([name isEqualToString:@"lfind"])    return ESBridgeCLIStageKindLfind;
    if ([name isEqualToString:@"grep"]   ||
        [name isEqualToString:@"discover"]) return ESBridgeCLIStageKindFilter;
    if ([name isEqualToString:@"w2vgrep"])  return ESBridgeCLIStageKindRanker;
    if ([name isEqualToString:@"sort"])     return ESBridgeCLIStageKindReorder;
    if ([name isEqualToString:@"head"]   ||
        [name isEqualToString:@"tail"])     return ESBridgeCLIStageKindSlice;
    if ([name isEqualToString:@"wc"])       return ESBridgeCLIStageKindCounter;
    if ([name isEqualToString:@"cat"])      return ESBridgeCLIStageKindReader;
    return ESBridgeCLIStageKindUnknown;
}

// Diagnostic line, command-aware annotations.
static NSString *BuildDiagLine(ESBridgeCLIStage *stage,
                               BOOL isFirst,
                               NSArray<NSDictionary *> * _Nullable prior,
                               NSArray<NSDictionary *> *result) {
    NSString *spelling = [stage description];
    NSString *prefixed = isFirst ? spelling : [@"| " stringByAppendingString:spelling];
    NSString *padded = DiagPad(prefixed);

    NSString *annotation = @"";
    ESBridgeCLIStageKind kind = KindForName(stage.name);
    NSUInteger rn = result.count;
    NSUInteger pn = prior.count;

    switch (kind) {
        case ESBridgeCLIStageKindFilter:
            if (rn == 0) {
                annotation = @"  (empty — try a different filter or re-order)";
            } else if (prior && rn < pn) {
                double pct = (double)rn / (double)pn * 100.0;
                if (pct < 10.0)        annotation = [NSString stringWithFormat:@"  (highly selective: %.0f%%)", pct];
                else if (pct > 90.0)   annotation = [NSString stringWithFormat:@"  (barely narrowed: %.0f%%)", pct];
                else                   annotation = [NSString stringWithFormat:@"  (selectivity: %.0f%%)", pct];
            }
            break;
        case ESBridgeCLIStageKindRanker:
            if (rn == 0) {
                annotation = @"  (empty — try a different filter or re-order)";
            } else if (prior && rn == pn) {
                annotation = @"  (re-rank only — semantic doesn't filter)";
            }
            break;
        default:
            // Reorder, Slice, Counter, Reader, Lfind, Unknown — no annotation.
            break;
    }

    return [NSString stringWithFormat:@"%@→ %lu hits%@",
            padded, (unsigned long)rn, annotation];
}

#pragma mark - Population helpers

// Normalize a server tool's response into a flat array of memory dicts.
// Different tools return memories under different keys (results, memories)
// and with different field names (title vs memory_title). Normalize here.
static NSArray<NSDictionary *> *NormalizeMemoryList(NSDictionary * _Nullable response) {
    if (!response) return @[];

    // memory_search/recent/tagged: response[results] = [{title,...}, ...]
    NSArray *list = response[@"results"];

    // memory_discover: response[memories]
    if (![list isKindOfClass:NSArray.class]) {
        list = response[@"memories"];
    }
    if (![list isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:list.count];
    NSMutableSet<NSString *> *seenTitles = [NSMutableSet set];

    for (id entry in list) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *e = (NSDictionary *)entry;

        // memory_grep returns memory_title; everything else returns title.
        NSString *title = e[@"title"] ?: e[@"memory_title"];
        if (![title isKindOfClass:NSString.class] || title.length == 0) continue;

        // Dedupe — grep may return the same memory under multiple sources.
        if ([seenTitles containsObject:title]) continue;
        [seenTitles addObject:title];

        // Carry forward whatever fields the source provided. Always normalize
        // to "title" key for downstream stages.
        NSMutableDictionary *normalized = [e mutableCopy];
        normalized[@"title"] = title;
        [normalized removeObjectForKey:@"memory_title"];
        [out addObject:normalized];
    }
    return out;
}

// Bridge-side intersection of two populations by title. Preserves the order
// of `withOrder` (the stage that should determine ranking — typically the
// downstream / ranker stage).
static NSArray<NSDictionary *> *IntersectByTitle(NSArray<NSDictionary *> *withOrder,
                                                  NSArray<NSDictionary *> *otherPop) {
    if (otherPop.count == 0) return @[];
    NSMutableSet<NSString *> *otherTitles = [NSMutableSet setWithCapacity:otherPop.count];
    for (NSDictionary *m in otherPop) {
        NSString *t = m[@"title"];
        if (t) [otherTitles addObject:t];
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *m in withOrder) {
        NSString *t = m[@"title"];
        if (t && [otherTitles containsObject:t]) [out addObject:m];
    }
    return out;
}

#pragma mark - Helper: parse integer (positional or flag)

static NSInteger ParseCount(ESBridgeCLIStage *stage, NSInteger defaultValue) {
    if (stage.positional.count > 0) {
        NSInteger v = [stage.positional[0] integerValue];
        if (v > 0) return v;
    }
    id flagVal = stage.flags[@"limit"] ?: stage.flags[@"n"];
    if ([flagVal isKindOfClass:NSString.class]) {
        NSInteger v = [(NSString *)flagVal integerValue];
        if (v > 0) return v;
    }
    if ([flagVal isKindOfClass:NSNumber.class]) {
        NSInteger v = [(NSNumber *)flagVal integerValue];
        if (v > 0) return v;
    }
    return defaultValue;
}

#pragma mark - lfind (deferred)

// lfind doesn't fire a server call by itself — it accumulates filters that
// the next fetcher consumes. If the pipeline ends without a fetcher (e.g.
// `lfind --tag X | head 5`), the executor calls ESBridgeCLIFlushPendingFilters
// at the end.
static ESBridgeCLIStageResult RunLfind(ESBridgeCLIStage *stage,
                                        NSArray<NSDictionary *> * _Nullable prior,
                                        NSArray<NSString *> * _Nullable pendingTags,
                                        NSNumber * _Nullable pendingDays,
                                        BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};

    NSString *tag = stage.flags[@"tag"];
    id daysVal = stage.flags[@"days"];
    NSNumber *daysNum = nil;
    if ([daysVal isKindOfClass:NSString.class]) {
        NSInteger d = [(NSString *)daysVal integerValue];
        if (d > 0) daysNum = @(d);
    } else if ([daysVal isKindOfClass:NSNumber.class]) {
        daysNum = (NSNumber *)daysVal;
    }

    NSMutableArray<NSString *> *tags = pendingTags ? [pendingTags mutableCopy] : [NSMutableArray array];
    if ([tag isKindOfClass:NSString.class] && tag.length > 0) {
        [tags addObject:tag];
    }

    result.outPendingTags = tags.count > 0 ? [tags copy] : nil;
    result.outPendingDays = daysNum ?: pendingDays;
    result.population = prior;  // pass through unchanged
    result.deferred = YES;       // signal to executor: no fetcher fired
    // Diagnostic shows lfind ran but didn't fetch.
    result.diagLine = [NSString stringWithFormat:@"%@→ deferred (filters)",
                        DiagPad(isFirst ? [stage description] : [@"| " stringByAppendingString:[stage description]])];
    return result;
}

#pragma mark - w2vgrep

static ESBridgeCLIStageResult RunW2vgrep(ESBridgeCLIStage *stage,
                                          NSArray<NSDictionary *> * _Nullable prior,
                                          NSArray<NSString *> * _Nullable pendingTags,
                                          NSNumber * _Nullable pendingDays,
                                          BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};

    NSString *query = stage.positional.firstObject;
    if (!query || query.length == 0) {
        result.error = @"missing_argument";
        result.errorMessage = @"w2vgrep requires a query — try: w2vgrep \"...\"";
        result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
        return result;
    }

    NSInteger limit = ParseCount(stage, 200);
    if (limit < 1) limit = 1;
    if (limit > 50) limit = 50;  // server caps memory_search at 50

    NSString *focus = stage.flags[@"focus"];

    NSMutableDictionary *args = [NSMutableDictionary dictionary];
    args[@"query"] = query;
    args[@"limit"] = @(limit);
    if ([focus isKindOfClass:NSString.class] && focus.length > 0) args[@"focus"] = focus;
    if (pendingTags.count > 0) args[@"tags"] = pendingTags;

    NSError *err = nil;
    NSDictionary *response = ESBridgeCallTool(@"memory_search", args, &err);
    if (!response) {
        result.error = @"server_call_failed";
        result.errorMessage = err.localizedDescription ?: @"memory_search call failed";
        result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
        return result;
    }

    NSArray<NSDictionary *> *population = NormalizeMemoryList(response);

    // If we have a prior population AND we didn't already use tag fusion,
    // intersect bridge-side. Tag fusion (pendingTags filtering server-side)
    // typically obviates this.
    if (prior && pendingTags.count == 0) {
        population = IntersectByTitle(population, prior);
    }

    result.population = population;
    result.diagLine = BuildDiagLine(stage, isFirst, prior, population);
    // pendingTags consumed; clear them.
    return result;
}

#pragma mark - grep

static ESBridgeCLIStageResult RunGrep(ESBridgeCLIStage *stage,
                                       NSArray<NSDictionary *> * _Nullable prior,
                                       NSArray<NSString *> * _Nullable pendingTags,
                                       NSNumber * _Nullable pendingDays,
                                       BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};

    NSString *pattern = stage.positional.firstObject;
    if (!pattern || pattern.length == 0) {
        result.error = @"missing_argument";
        result.errorMessage = @"grep requires a pattern — try: grep \"...\"";
        result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
        return result;
    }

    NSMutableDictionary *args = [NSMutableDictionary dictionary];
    args[@"pattern"] = pattern;
    args[@"output_mode"] = @"files_with_matches";
    args[@"head_limit"] = @(1000);

    if ([stage.flags[@"regex"] isKindOfClass:NSNumber.class]) {
        args[@"regex"] = stage.flags[@"regex"];
    }
    if ([stage.flags[@"case-sensitive"] isKindOfClass:NSNumber.class]) {
        args[@"case_sensitive"] = stage.flags[@"case-sensitive"];
    }
    NSString *scope = stage.flags[@"scope"];
    if ([scope isKindOfClass:NSString.class] && scope.length > 0) {
        args[@"scope"] = scope;
    }
    if (pendingTags.count > 0) args[@"tags"] = pendingTags;

    NSError *err = nil;
    NSDictionary *response = ESBridgeCallTool(@"memory_grep", args, &err);
    if (!response) {
        result.error = @"server_call_failed";
        result.errorMessage = err.localizedDescription ?: @"memory_grep call failed";
        result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
        return result;
    }

    NSArray<NSDictionary *> *population = NormalizeMemoryList(response);

    if (prior && pendingTags.count == 0) {
        population = IntersectByTitle(population, prior);
    }

    result.population = population;
    result.diagLine = BuildDiagLine(stage, isFirst, prior, population);
    return result;
}

#pragma mark - discover

static ESBridgeCLIStageResult RunDiscover(ESBridgeCLIStage *stage,
                                           NSArray<NSDictionary *> * _Nullable prior,
                                           NSArray<NSString *> * _Nullable pendingTags,
                                           NSNumber * _Nullable pendingDays,
                                           BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};

    NSString *mode = stage.flags[@"mode"];
    if (![mode isKindOfClass:NSString.class] || mode.length == 0) {
        mode = stage.positional.firstObject;
    }
    if (mode.length == 0) {
        result.error = @"missing_argument";
        result.errorMessage = @"discover requires --mode (forgotten, hot, hubs, lost, popular, revised, discussed)";
        result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
        return result;
    }

    NSInteger limit = ParseCount(stage, 200);
    if (limit < 1) limit = 1;

    NSDictionary *args = @{ @"mode": mode, @"limit": @(limit) };

    NSError *err = nil;
    NSDictionary *response = ESBridgeCallTool(@"memory_discover", args, &err);
    if (!response) {
        result.error = @"server_call_failed";
        result.errorMessage = err.localizedDescription ?: @"memory_discover call failed";
        result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
        return result;
    }

    NSArray<NSDictionary *> *population = NormalizeMemoryList(response);

    if (prior) {
        population = IntersectByTitle(population, prior);
    }

    result.population = population;
    result.diagLine = BuildDiagLine(stage, isFirst, prior, population);
    return result;
}

#pragma mark - sort

static NSArray<NSDictionary *> *SortByKey(NSArray<NSDictionary *> *population,
                                          NSString *byKey) {
    NSString *field;
    BOOL ascending;
    if      ([byKey isEqualToString:@"oldest"])   { field = @"dateCreated";  ascending = YES; }
    else if ([byKey isEqualToString:@"recent"])   { field = @"dateModified"; ascending = NO;  }
    else if ([byKey isEqualToString:@"accessed"]) { field = @"lastAccessed"; ascending = NO;  }
    else if ([byKey isEqualToString:@"popular"])  { field = @"accessCount";  ascending = NO;  }
    else if ([byKey isEqualToString:@"alphabetical"]) {
        return [population sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [(a[@"title"] ?: @"") caseInsensitiveCompare:(b[@"title"] ?: @"")];
        }];
    } else {
        field = @"dateModified"; ascending = NO;
    }

    return [population sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        id va = a[field], vb = b[field];
        // nil sorts last regardless of direction
        if (!va && !vb) return NSOrderedSame;
        if (!va)        return NSOrderedDescending;
        if (!vb)        return NSOrderedAscending;
        NSComparisonResult r = NSOrderedSame;
        if ([va isKindOfClass:NSString.class] && [vb isKindOfClass:NSString.class]) {
            r = [(NSString *)va compare:(NSString *)vb];
        } else if ([va isKindOfClass:NSNumber.class] && [vb isKindOfClass:NSNumber.class]) {
            r = [(NSNumber *)va compare:(NSNumber *)vb];
        }
        return ascending ? r : (r == NSOrderedAscending ? NSOrderedDescending
                              : r == NSOrderedDescending ? NSOrderedAscending : NSOrderedSame);
    }];
}

static ESBridgeCLIStageResult RunSort(ESBridgeCLIStage *stage,
                                       NSArray<NSDictionary *> * _Nullable prior,
                                       NSArray<NSString *> * _Nullable pendingTags,
                                       NSNumber * _Nullable pendingDays,
                                       BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};

    NSString *byKey = stage.positional.firstObject;
    if (byKey.length == 0) byKey = stage.flags[@"by"];
    if (![byKey isKindOfClass:NSString.class] || byKey.length == 0) byKey = @"recent";

    static NSSet *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = [NSSet setWithArray:@[@"recent", @"oldest", @"popular",
                                       @"accessed", @"alphabetical"]];
    });
    if (![known containsObject:byKey]) {
        result.error = @"unknown_sort_key";
        result.errorMessage = [NSString stringWithFormat:
            @"sort: unknown key '%@'. Try one of: recent, oldest, popular, accessed, alphabetical.", byKey];
        result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
        return result;
    }

    // Special case: if pending lfind --tag X is present and not yet flushed,
    // we can do server-side sort via memory_tagged(tag=X, sort=KEY).
    // This gives us metadata-driven sort (popular by accessCount, etc) that
    // we can't compute bridge-side from a list of titles alone.
    if (!prior && pendingTags.count > 0) {
        NSDictionary *args = @{
            @"tag": pendingTags.firstObject,
            @"sort": byKey,
            @"limit": @(500),
            @"include_summary": @YES,
        };
        NSError *err = nil;
        NSDictionary *response = ESBridgeCallTool(@"memory_tagged", args, &err);
        if (!response) {
            result.error = @"server_call_failed";
            result.errorMessage = err.localizedDescription ?: @"memory_tagged call failed";
            result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
            return result;
        }
        NSArray<NSDictionary *> *population = NormalizeMemoryList(response);
        result.population = population;
        result.diagLine = BuildDiagLine(stage, isFirst, prior, population);
        return result;
    }

    // Bridge-side sort. Works when the prior population already carries
    // the metadata (e.g., from memory_recent or memory_discover).
    NSArray<NSDictionary *> *sorted = SortByKey(prior ?: @[], byKey);
    result.population = sorted;
    result.outPendingTags = pendingTags;
    result.outPendingDays = pendingDays;
    result.diagLine = BuildDiagLine(stage, isFirst, prior, sorted);
    return result;
}

#pragma mark - head, tail

static ESBridgeCLIStageResult RunSlice(ESBridgeCLIStage *stage,
                                        NSArray<NSDictionary *> * _Nullable prior,
                                        NSArray<NSString *> * _Nullable pendingTags,
                                        NSNumber * _Nullable pendingDays,
                                        BOOL isFirst,
                                        BOOL fromHead) {
    ESBridgeCLIStageResult result = {0};
    NSInteger n = ParseCount(stage, 10);
    if (n < 0) n = 0;

    // If a deferred lfind is sitting in pendingFilters with no population,
    // flush it here (with limit=N for efficiency).
    NSArray<NSDictionary *> *source = prior;
    if (!source && (pendingTags || pendingDays)) {
        NSMutableDictionary *args = [NSMutableDictionary dictionary];
        if (pendingTags.count == 1) {
            args[@"tag"] = pendingTags.firstObject;
            args[@"limit"] = @(MIN(500, n));
            args[@"include_summary"] = @YES;
            NSError *err = nil;
            NSDictionary *response = ESBridgeCallTool(@"memory_tagged", args, &err);
            if (!response) {
                result.error = @"server_call_failed";
                result.errorMessage = err.localizedDescription ?: @"memory_tagged call failed";
                result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
                return result;
            }
            source = NormalizeMemoryList(response);
        } else {
            // memory_recent supports tags array + days
            if (pendingTags.count > 1) args[@"tags"] = pendingTags;
            if (pendingDays) args[@"days"] = pendingDays;
            args[@"limit"] = @(n);
            args[@"include_summary"] = @YES;
            NSError *err = nil;
            NSDictionary *response = ESBridgeCallTool(@"memory_recent", args, &err);
            if (!response) {
                result.error = @"server_call_failed";
                result.errorMessage = err.localizedDescription ?: @"memory_recent call failed";
                result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
                return result;
            }
            source = NormalizeMemoryList(response);
        }
    }

    if (!source) source = @[];

    NSArray<NSDictionary *> *out;
    if ((NSUInteger)n >= source.count) {
        out = source;
    } else if (fromHead) {
        out = [source subarrayWithRange:NSMakeRange(0, n)];
    } else {
        out = [source subarrayWithRange:NSMakeRange(source.count - n, n)];
    }

    result.population = out;
    result.diagLine = BuildDiagLine(stage, isFirst, prior, out);
    return result;
}

#pragma mark - Population stage dispatcher

ESBridgeCLIStageResult
ESBridgeCLIRunPopulationStage(ESBridgeCLIStage *stage,
                              NSArray<NSDictionary *> * _Nullable prior,
                              NSArray<NSString *> * _Nullable pendingTags,
                              NSNumber * _Nullable pendingDays,
                              BOOL isFirst) {
    NSString *name = stage.name;
    if ([name isEqualToString:@"lfind"])    return RunLfind(stage, prior, pendingTags, pendingDays, isFirst);
    if ([name isEqualToString:@"w2vgrep"])  return RunW2vgrep(stage, prior, pendingTags, pendingDays, isFirst);
    if ([name isEqualToString:@"grep"])     return RunGrep(stage, prior, pendingTags, pendingDays, isFirst);
    if ([name isEqualToString:@"discover"]) return RunDiscover(stage, prior, pendingTags, pendingDays, isFirst);
    if ([name isEqualToString:@"sort"])     return RunSort(stage, prior, pendingTags, pendingDays, isFirst);
    if ([name isEqualToString:@"head"])     return RunSlice(stage, prior, pendingTags, pendingDays, isFirst, YES);
    if ([name isEqualToString:@"tail"])     return RunSlice(stage, prior, pendingTags, pendingDays, isFirst, NO);

    ESBridgeCLIStageResult result = {0};
    result.error = @"unknown_command";
    result.errorMessage = [NSString stringWithFormat:
        @"unknown command: %@. Try 'man' to see available commands.", name];
    result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
    return result;
}

#pragma mark - Flush pending lfind

ESBridgeCLIStageResult
ESBridgeCLIFlushPendingFilters(NSArray<NSString *> * _Nullable pendingTags,
                               NSNumber * _Nullable pendingDays,
                               BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};

    NSDictionary *response = nil;
    NSError *err = nil;

    if (pendingTags.count == 1 && !pendingDays) {
        // Single tag, no days → memory_tagged
        NSDictionary *args = @{
            @"tag": pendingTags.firstObject,
            @"limit": @(500),
            @"include_summary": @YES,
        };
        response = ESBridgeCallTool(@"memory_tagged", args, &err);
    } else {
        // Anything else (multi-tag, days, or no filters) → memory_recent
        NSMutableDictionary *args = [NSMutableDictionary dictionary];
        if (pendingTags.count > 0) args[@"tags"] = pendingTags;
        if (pendingDays) args[@"days"] = pendingDays;
        args[@"limit"] = @(500);
        args[@"include_summary"] = @YES;
        response = ESBridgeCallTool(@"memory_recent", args, &err);
    }

    if (!response) {
        result.error = @"server_call_failed";
        result.errorMessage = err.localizedDescription ?: @"server call failed";
        result.diagLine = @"";
        return result;
    }

    result.population = NormalizeMemoryList(response);
    result.diagLine = @"";  // No diag line — lfind already emitted "deferred"
    return result;
}

#pragma mark - Terminal stages: cat, wc

static ESBridgeCLIStageResult RunCat(ESBridgeCLIStage *stage,
                                      NSArray<NSDictionary *> * _Nullable prior,
                                      BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};

    NSArray<NSDictionary *> *memoriesToRead = nil;
    if (prior) {
        memoriesToRead = prior;
    } else if (stage.positional.count > 0) {
        memoriesToRead = @[ @{ @"title": stage.positional.firstObject } ];
    } else {
        memoriesToRead = @[];
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:memoriesToRead.count];
    for (NSDictionary *m in memoriesToRead) {
        NSString *title = m[@"title"];
        if (!title) continue;
        NSDictionary *args = @{ @"title": title };
        NSError *err = nil;
        NSDictionary *response = ESBridgeCallTool(@"memory_read", args, &err);
        if (!response) continue;
        [out addObject:response];
    }

    result.response = @{ @"results": out, @"count": @(out.count) };
    result.diagLine = BuildDiagLine(stage, isFirst, prior, prior ?: @[]);
    return result;
}

static ESBridgeCLIStageResult RunWC(ESBridgeCLIStage *stage,
                                     NSArray<NSDictionary *> * _Nullable prior,
                                     BOOL isFirst) {
    ESBridgeCLIStageResult result = {0};
    NSUInteger count = prior.count;
    result.response = @{ @"count": @(count) };
    result.diagLine = BuildDiagLine(stage, isFirst, prior, prior ?: @[]);
    return result;
}

ESBridgeCLIStageResult
ESBridgeCLIRunTerminal(ESBridgeCLIStage *stage,
                       NSArray<NSDictionary *> * _Nullable prior,
                       BOOL isFirst) {
    if ([stage.name isEqualToString:@"cat"]) return RunCat(stage, prior, isFirst);
    if ([stage.name isEqualToString:@"wc"])  return RunWC(stage, prior, isFirst);

    ESBridgeCLIStageResult result = {0};
    result.error = @"unknown_terminal";
    result.errorMessage = [NSString stringWithFormat:@"unknown terminal command: %@", stage.name];
    result.diagLine = BuildDiagLine(stage, isFirst, prior, @[]);
    return result;
}

#pragma mark - Man pages

static NSString *const kManIndex =
@"Available commands:\n"
@"  cat       read a memory's full body\n"
@"  discover  structural lenses on the archive (forgotten, hot, hubs, lost, ...)\n"
@"  grep      literal or regex pattern match in body and attachments\n"
@"  head      first N results from a population\n"
@"  lfind     filter by metadata (tag, days)\n"
@"  man       this help — try 'man <command>' for details\n"
@"  sort      reorder by recent, popular, accessed, oldest, alphabetical\n"
@"  tail      last N results (oldest, lowest-scoring — diagnostic use)\n"
@"  w2vgrep   semantic similarity search (vector cosine)\n"
@"  wc        count results in a population without surfacing them\n"
@"\n"
@"Pipelines compose with |. The output of each stage feeds the next.\n"
@"Try 'man w2vgrep' for a worked example.\n"
@"\n"
@"If results disappoint, vary the pipeline: reorder stages, replace one\n"
@"command with another at the same position, or change a parameter and\n"
@"re-run. Be persistent. Be creative. You will find it eventually.\n";

static NSString *const kManLfind =
@"NAME\n"
@"    lfind — filter memories by metadata\n"
@"\n"
@"SYNOPSIS\n"
@"    lfind [--tag NAME] [--days N]\n"
@"\n"
@"DESCRIPTION\n"
@"    Filter the archive by metadata. lfind is lazy — it accumulates filters\n"
@"    that the next stage's server call consumes. Standalone, lfind flushes\n"
@"    via memory_tagged or memory_recent at end of pipeline.\n"
@"\n"
@"    --tag NAME     Memories carrying this exact tag (proper noun).\n"
@"    --days N       Memories modified in the last N days.\n"
@"\n"
@"EXAMPLES\n"
@"    All memories tagged 'Isolde':\n"
@"        lfind --tag \"Isolde\" | head 10\n"
@"\n"
@"    Recent within a tag (lfind+w2vgrep fuse into one server call):\n"
@"        lfind --tag \"ES Memory\" | w2vgrep \"branching\" | head 5\n"
@"\n"
@"    Last N days, no tag:\n"
@"        lfind --days 7 | head 10\n"
@"\n"
@"SEE ALSO\n"
@"    w2vgrep, grep, discover, sort, head\n";

static NSString *const kManW2vgrep =
@"NAME\n"
@"    w2vgrep — semantic similarity search (vector cosine)\n"
@"\n"
@"SYNOPSIS\n"
@"    w2vgrep \"query\" [--limit N] [--focus day|week|month|none]\n"
@"\n"
@"DESCRIPTION\n"
@"    Vector cosine similarity over the corpus, ranked by relevance. When\n"
@"    piped from lfind --tag X, the bridge fuses the tag filter into the\n"
@"    server call (one HTTP call, server-side scoping).\n"
@"\n"
@"    Not for proper nouns — those are exact, use 'lfind --tag' instead.\n"
@"\n"
@"    USAGE NOTE: w2vgrep alone over the full corpus dilutes — semantic\n"
@"    similarity spreads thin across hundreds of candidates and the top\n"
@"    results aren't meaningfully better than the bottom. Reach for\n"
@"    grep or lfind first; reach for w2vgrep second.\n"
@"\n"
@"    --limit N    Max results (default 10, max 50).\n"
@"    --focus      Temporal weighting override.\n"
@"\n"
@"EXAMPLES\n"
@"    Refine a tagged population by concept:\n"
@"        lfind --tag \"ES Memory\" | w2vgrep \"branching\" | head 10\n"
@"\n"
@"    Pattern-narrow then concept-rank:\n"
@"        grep \"Humboldt\" | w2vgrep \"France Prussia Napoleon\" | head 5\n"
@"\n"
@"    Buried-signal recovery:\n"
@"        discover --mode forgotten | w2vgrep \"vector embedding\" | head 10\n"
@"\n"
@"DIAGNOSTICS\n"
@"    (re-rank only) means the candidate set wasn't narrowed — semantic\n"
@"    ranks every candidate. If you see this on the first stage of a\n"
@"    pipeline, your population is too broad — add a narrowing stage.\n"
@"\n"
@"SEE ALSO\n"
@"    grep, lfind, discover, head\n";

static NSString *const kManGrep =
@"NAME\n"
@"    grep — literal or regex pattern match in memory body and attachments\n"
@"\n"
@"SYNOPSIS\n"
@"    grep \"pattern\" [--regex] [--scope all|body|attachments] [--case-sensitive]\n"
@"\n"
@"DESCRIPTION\n"
@"    Pattern search within memory text. Literal substring by default;\n"
@"    --regex enables ICU regex. Returns memories containing at least one\n"
@"    match. When piped from lfind --tag X, fuses the tag filter server-side.\n"
@"\n"
@"EXAMPLES\n"
@"    grep \"FSEvents\"\n"
@"    lfind --tag \"ES Memory\" | grep --regex \"NSCache|NSIndexPath\"\n"
@"    discover --mode hubs | grep \"CloudKit\" | head 5\n"
@"\n"
@"SEE ALSO\n"
@"    w2vgrep, lfind, discover\n";

static NSString *const kManSort =
@"NAME\n"
@"    sort — reorder a population\n"
@"\n"
@"SYNOPSIS\n"
@"    sort KEY                     # positional (preferred)\n"
@"    sort --by KEY                # equivalent flag form\n"
@"\n"
@"    KEY: recent | oldest | popular | accessed | alphabetical\n"
@"\n"
@"DESCRIPTION\n"
@"    Reorder the prior population. Default key is 'recent'.\n"
@"\n"
@"    Special: when sort follows lfind --tag X with no other intervening\n"
@"    stage, the bridge fuses into memory_tagged(tag=X, sort=KEY) — the\n"
@"    server-side sort uses authoritative metadata (accessCount, dateCreated,\n"
@"    etc) that wouldn't be available bridge-side.\n"
@"\n"
@"    Unknown keys error rather than silently defaulting.\n"
@"\n"
@"EXAMPLES\n"
@"    Most-accessed memories tagged Isolde — a portrait by attention:\n"
@"        lfind --tag \"Isolde\" | sort popular | head 10\n"
@"\n"
@"    Oldest first within a tag:\n"
@"        lfind --tag \"Kolja\" | sort oldest | head 5\n"
@"\n"
@"SEE ALSO\n"
@"    head, tail\n";

static NSString *const kManHead =
@"NAME\n"
@"    head — first N results from a population\n"
@"\n"
@"SYNOPSIS\n"
@"    head N\n"
@"    head --limit N\n"
@"\n"
@"DESCRIPTION\n"
@"    Slice the first N memories from the prior population. Default 10.\n"
@"    When piped from a deferred lfind, applies the limit server-side\n"
@"    (efficient for tag enumeration).\n"
@"\n"
@"EXAMPLES\n"
@"    w2vgrep \"architecture\" | head 5\n"
@"\n"
@"SEE ALSO\n"
@"    tail, sort\n";

static NSString *const kManTail =
@"NAME\n"
@"    tail — last N results from a population (diagnostic)\n"
@"\n"
@"SYNOPSIS\n"
@"    tail N\n"
@"\n"
@"DESCRIPTION\n"
@"    Slice the last N memories. Useful diagnostically — the bottom of a\n"
@"    semantic ranking shows what your filter is barely matching.\n"
@"\n"
@"EXAMPLES\n"
@"    w2vgrep \"file system\" | tail 5\n"
@"\n"
@"SEE ALSO\n"
@"    head, sort\n";

static NSString *const kManDiscover =
@"NAME\n"
@"    discover — structural lenses on the archive\n"
@"\n"
@"SYNOPSIS\n"
@"    discover --mode forgotten|hot|hubs|lost|popular|revised|discussed [--limit N]\n"
@"\n"
@"DESCRIPTION\n"
@"    Apply a structural mode to the archive. Modes:\n"
@"\n"
@"    hot         where the conversation is now (recency-weighted marginalia)\n"
@"    forgotten   accessed long ago, rarely — buried signal\n"
@"    lost        never accessed — orphans waiting\n"
@"    hubs        most connected — load-bearing nodes\n"
@"    popular     most accessed — watch for orthodoxy\n"
@"    revised     most edited — living documents\n"
@"    discussed   most commented all-time\n"
@"\n"
@"EXAMPLES\n"
@"    Reorient at session start:\n"
@"        discover --mode hot | head 5\n"
@"\n"
@"    Buried-signal recovery (canonical chain):\n"
@"        discover --mode forgotten | w2vgrep \"vector embedding\" | head 10\n"
@"\n"
@"SEE ALSO\n"
@"    lfind, w2vgrep\n";

static NSString *const kManCat =
@"NAME\n"
@"    cat — read full memory body\n"
@"\n"
@"SYNOPSIS\n"
@"    cat \"Title\"\n"
@"    PIPELINE | cat\n"
@"\n"
@"DESCRIPTION\n"
@"    Read full body, summary, and metadata. With a positional title,\n"
@"    looks up that specific memory. With a prior pipeline, calls\n"
@"    memory_read for each in the population. Combine with 'head N' to\n"
@"    limit the read.\n"
@"\n"
@"EXAMPLES\n"
@"    cat \"The Crystalline Homecoming\"\n"
@"    w2vgrep \"resurrection\" | head 1 | cat\n"
@"\n"
@"SEE ALSO\n"
@"    lfind, w2vgrep\n";

static NSString *const kManWC =
@"NAME\n"
@"    wc — count results without surfacing them\n"
@"\n"
@"SYNOPSIS\n"
@"    PIPELINE | wc\n"
@"\n"
@"DESCRIPTION\n"
@"    Cheap peek at population size. Useful for probing before committing\n"
@"    to a more expensive pipeline.\n"
@"\n"
@"EXAMPLES\n"
@"    lfind --tag \"Isolde\" | wc\n"
@"    lfind --tag \"Isolde\" | w2vgrep \"resurrection\" | wc\n"
@"\n"
@"SEE ALSO\n"
@"    head\n";

static NSString *const kManMan =
@"NAME\n"
@"    man — documentation for memory_cli commands\n"
@"\n"
@"SYNOPSIS\n"
@"    man\n"
@"    man COMMAND\n"
@"\n"
@"DESCRIPTION\n"
@"    With no argument, lists all commands with one-line synopses.\n"
@"    With a command name, returns its full man page.\n"
@"\n"
@"EXAMPLES\n"
@"    man\n"
@"    man w2vgrep\n";

static NSDictionary<NSString *, NSString *> *AllManPages(void) {
    static NSDictionary *pages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pages = @{
            @"lfind":    kManLfind,
            @"w2vgrep":  kManW2vgrep,
            @"grep":     kManGrep,
            @"sort":     kManSort,
            @"head":     kManHead,
            @"tail":     kManTail,
            @"discover": kManDiscover,
            @"cat":      kManCat,
            @"wc":       kManWC,
            @"man":      kManMan,
        };
    });
    return pages;
}

NSDictionary *ESBridgeCLIRunMan(NSString * _Nullable target) {
    if (target.length == 0) {
        return @{ @"man": kManIndex };
    }
    NSString *page = AllManPages()[target];
    if (page) return @{ @"man": page };
    return @{
        @"error":   @"unknown_command",
        @"message": [NSString stringWithFormat:
            @"no man page for '%@'. Try 'man' to see what's available.", target],
    };
}
