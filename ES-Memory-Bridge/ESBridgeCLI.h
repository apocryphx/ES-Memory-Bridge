//
//  ESBridgeCLI.h
//  ES-Memory-Bridge
//
//  Pipeline interpreter for memory_cli, hosted in the bridge.
//
//  Why the bridge: the CLI is composition logic — it has no business in the
//  data server. The bridge is the cognitive layer between Claude Desktop
//  and the ES Memory MCP server. Each pipeline stage maps to one (or, for
//  rare compositions, two) HTTP calls to the server's existing per-tool
//  MCP surface. The server stays at its original API; the bridge does the
//  Unix-style composition work and presents memory_cli as a single tool to
//  the LLM.
//
//  Architecture:
//    Claude Desktop ──stdio──> bridge.memory_cli  ──HTTP──> server.memory_*
//    (sees one tool)            (parses pipeline,            (per-tool MCP
//                                makes 1+ HTTP calls,         surface)
//                                composes results)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Tokenization

/// One token from shell-style lexing. Either a word (possibly quoted) or
/// the pipe operator. Preserves quoted-ness so the parser knows whether
/// "head" was a literal value or a command name.
@interface ESBridgeCLIToken : NSObject
@property (nonatomic, readonly) NSString *value;
@property (nonatomic, readonly) BOOL isPipe;
@property (nonatomic, readonly) BOOL wasQuoted;
@end

/// Tokenize a pipeline expression. Handles double-quoted strings (preserving
/// internal spaces and `\"`/`\\` backslash escapes), single-quoted strings
/// (literal, no escapes), bare words, and the `|` operator outside quotes.
/// Returns nil and populates *errorOut on syntax errors (unterminated quotes).
NSArray<ESBridgeCLIToken *> * _Nullable
ESBridgeCLITokenize(NSString *expression, NSError * _Nullable * _Nullable errorOut);

#pragma mark - Parsed pipeline shape

/// One command invocation parsed from tokens. e.g. "lfind --tag 'X' --days 7"
/// becomes name="lfind", positional=[], flags={"tag":"X", "days":"7"}.
/// Boolean flags ("--regex" with no value before the next flag) become @YES.
@interface ESBridgeCLIStage : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSArray<NSString *> *positional;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *flags;
@end

/// Parse a flat token list into ordered stages. Returns nil and populates
/// *errorOut on structural errors (empty stage, dangling pipe, unknown flag
/// syntax).
NSArray<ESBridgeCLIStage *> * _Nullable
ESBridgeCLIParseStages(NSArray<ESBridgeCLIToken *> *tokens,
                       NSError * _Nullable * _Nullable errorOut);

#pragma mark - HTTP to server (declared here so command handlers can call it)

/// Forward a JSON-RPC line to the host's MCP endpoint. Implemented in main.m.
/// Returns response body or nil on error.
NSString * _Nullable ForwardRequest(NSString *jsonLine, NSError * _Nullable * _Nullable outError);

/// Wraps a tools/call JSON-RPC envelope around the (toolName, arguments)
/// pair, forwards it to the server, parses the response, and returns the
/// inner tool-result dict.
///
/// On HTTP failure, JSON parse failure, or unexpected response shape:
/// returns nil and populates *errorOut. The caller must handle that.
NSDictionary * _Nullable
ESBridgeCallTool(NSString *toolName,
                 NSDictionary *arguments,
                 NSError * _Nullable * _Nullable errorOut);

#pragma mark - Execution

/// Execute a parsed pipeline. Returns the response dictionary that
/// memory_cli should serialize. Stages call into ESBridgeCLICommands.
///
/// Response shape on success:
///   {
///     "pipeline":  "lfind --tag X         → 11 hits\n"
///                  "| w2vgrep \"y\"        → 11 hits  (re-rank only)\n"
///                  "| head 5               → 5 hits",
///     "results":   [ {title, score?, summary?}, ... ]
///   }
///
/// On error:
///   { "error": "...", "message": "...", "pipeline": "..." }
NSDictionary *
ESBridgeCLIExecute(NSArray<ESBridgeCLIStage *> *stages);

NS_ASSUME_NONNULL_END
