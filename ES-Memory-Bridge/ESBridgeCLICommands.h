//
//  ESBridgeCLICommands.h
//  ES-Memory-Bridge
//
//  Stage handlers and man-page text for memory_cli, hosted in the bridge.
//
//  Each pipeline stage is implemented as a function that takes the prior
//  population (an array of memory dicts) plus the executor's "pending
//  filters" (accumulated from earlier lfind stages) and produces a new
//  population. Server calls go through ESBridgeCallTool (declared in
//  ESBridgeCLI.h).
//

#import <Foundation/Foundation.h>
#import "ESBridgeCLI.h"

NS_ASSUME_NONNULL_BEGIN

/// Result of running a single stage. Population stages set `population` and
/// `diagLine`; terminal stages set `response` and `diagLine`. `error` is set
/// only on stage-level errors that should abort the pipeline.
///
/// `outPendingTags` and `outPendingDays` are nullable carriers for filters
/// that lfind accumulates and downstream stages consume. The executor manages
/// them; handlers may set or clear them.
typedef struct {
    NSArray<NSDictionary *> * _Nullable population;
    NSDictionary * _Nullable response;
    NSString * _Nonnull diagLine;
    NSString * _Nullable error;
    NSString * _Nullable errorMessage;

    // Pending filters to thread to next stage (set by lfind, consumed by
    // w2vgrep/grep/etc).
    NSArray<NSString *> * _Nullable outPendingTags;
    NSNumber * _Nullable outPendingDays;

    // True if this stage produced no population — executor uses this to
    // decide whether to emit a flushed lfind call at end of pipeline.
    BOOL deferred;
} ESBridgeCLIStageResult;

/// Execute a population-shaped stage (lfind, w2vgrep, grep, sort, head,
/// tail, discover). `prior` is the previous stage's population (nil on
/// first stage). `pendingTags`/`pendingDays` are filters accumulated by
/// previous lfind stages, available for this stage to consume.
ESBridgeCLIStageResult
ESBridgeCLIRunPopulationStage(ESBridgeCLIStage *stage,
                              NSArray<NSDictionary *> * _Nullable prior,
                              NSArray<NSString *> * _Nullable pendingTags,
                              NSNumber * _Nullable pendingDays,
                              BOOL isFirst);

/// Execute a terminal stage (cat, wc).
ESBridgeCLIStageResult
ESBridgeCLIRunTerminal(ESBridgeCLIStage *stage,
                       NSArray<NSDictionary *> * _Nullable prior,
                       BOOL isFirst);

/// Flush a deferred lfind. Called by the executor when the pipeline ends
/// with pending tag/days filters that no fetcher consumed. Calls
/// memory_tagged or memory_recent with the accumulated filters.
ESBridgeCLIStageResult
ESBridgeCLIFlushPendingFilters(NSArray<NSString *> * _Nullable pendingTags,
                               NSNumber * _Nullable pendingDays,
                               BOOL isFirst);

/// `man` short-circuit. nil target → return the index. Otherwise, the man
/// page for that command name (or "unknown command" error).
NSDictionary *ESBridgeCLIRunMan(NSString * _Nullable target);

NS_ASSUME_NONNULL_END
