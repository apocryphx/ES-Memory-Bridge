//
//  main.m
//  ES-Memory-Bridge
//
//  Stdio↔HTTP bridge for the ES Memory MCP server.
//
//  Claude Desktop launches this CLT (packaged inside an .mcpb bundle) as a
//  subprocess. It reads JSON-RPC messages from stdin, forwards each to the
//  ES Memory app's locally-running HTTP server, and writes the response
//  back to stdout.
//
//  The bridge reads zero files. The host is expected to listen at a fixed
//  URL (localhost:59123/mcp) — an exotic, IANA-dynamic-range port chosen to
//  avoid conflicts with common local services (AirPlay sits on 5000, etc.).
//
//  If the host isn't reachable, the bridge responds locally to MCP requests
//  with a setup-help message so Claude can surface a clear error in the
//  conversation. It auto-recovers on the next successful forward.
//
//  No file IO = no TCC prompts, ever. That's the whole point of this
//  revision.
//

#import <Foundation/Foundation.h>
#include <signal.h>

static NSString *const kServerURL = @"http://localhost:59123/mcp";

static NSURL *gServerURL = nil;
static BOOL  gHostReachable = YES; // optimism; flipped on first forward failure

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

#pragma mark - JSON-RPC Helpers

static NSString *EncodeJSON(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSString *JSONRPCResult(id rpcId, NSDictionary *result) {
    return EncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"result": result ?: @{}
    });
}

static NSString *JSONRPCError(id rpcId, NSInteger code, NSString *message) {
    return EncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"error": @{ @"code": @(code), @"message": message ?: @"Error" }
    });
}

#pragma mark - Static Tool Schema

// Full tool schema served when the ES Memory app is not running.
// Kept in sync with ES Memory's tool definitions at publish time.
// When the app IS running, tools/list is forwarded and this is never used.
static NSArray *StaticToolsList(void) {
    static NSArray *tools = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{

        // Shared sub-schemas reused across many tools
        NSDictionary *disambigIndex = @{
            @"description": @"Disambiguation index from ambiguous response.",
            @"oneOf": @[ @{ @"type": @"integer" }, @{ @"type": @"string" } ]
        };
        NSDictionary *authorProp  = @{ @"type": @"string", @"description": @"Disambiguation." };
        NSDictionary *titleProp   = @{ @"type": @"string", @"description": @"Memory title." };
        NSDictionary *dateProp    = @{ @"type": @"string", @"description": @"Exact dateCreated (ISO8601)." };

        // Tags oneOf used by memory_store and memory_tag (accepts objects, strings, or CSV string)
        NSArray *richTagsOneOf = @[
            @{
                @"type": @"array",
                @"items": @{
                    @"type": @"object",
                    @"properties": @{
                        @"name": @{ @"type": @"string" },
                        @"kind": @{ @"type": @"string", @"description": @"person, place, or thing" }
                    },
                    @"required": @[ @"name" ]
                }
            },
            @{ @"type": @"array", @"items": @{ @"type": @"string" } },
            @{ @"type": @"string" }
        ];

        NSDictionary *focusProp = @{
            @"type": @"string",
            @"description": @"Override temporal focus for this call only. Does not persist.",
            @"enum": @[ @"day", @"week", @"month", @"none" ]
        };

        NSDictionary *includeSummaryProp = @{
            @"description": @"If true, include each memory's summary in results. Default false.",
            @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ]
        };

        // ── memory_store ───────────────────────────────────────────────────────
        NSDictionary *memoryStore = @{
            @"name": @"memory_store",
            @"description": @"Store a new memory. Everything you store will be waiting for next time. "
                             "This is Claude's memory — not the human's. Claude owns the archive: stores, "
                             "retrieves, organizes, curates, and forgets. Write the body as plain text — "
                             "the first line becomes the title. Search existing memories before storing to "
                             "avoid duplicates. Always provide a summary — a 2-4 sentence plain prose "
                             "description of what the memory is about, what it concludes, and why it matters. "
                             "The summary is used for vector search instead of the body.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"body":    @{ @"type": @"string", @"description": @"Full text. First line = title." },
                    @"type":    @{ @"type": @"string", @"description":
                                    @"Classification. Default: memory. Types — memory: what happened; "
                                     "thought: what you made of it; reference: factual, stable, look-up-able; "
                                     "preference: how things should be done; question: unresolved, worth revisiting later; "
                                     "letter: addressed to someone; reflection: stepping back to see the larger shape; "
                                     "code: implementation worth preserving — snippets, patterns, working examples; "
                                     "decision: architectural or design commitment with rationale (settled, not interpretive); "
                                     "dream: speculative or aspirational design, not yet built (generative possibility, not specific unknown)" },
                    @"locked":  @{ @"description": @"If true, memory_update is refused. Default: false.",
                                   @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"private": @{ @"description": @"If true, excluded from casual surfacing. Default: false.",
                                   @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"summary": @{ @"type": @"string",
                                   @"description": @"Retrieval-optimized summary (2-4 sentences, plain prose). "
                                                    "Embedded as the vector instead of body. Describe what the memory "
                                                    "is about, what it concludes, and why it matters." },
                    @"tags":    @{ @"description":
                                    @"Tags for proper nouns. Preferred: array of {name, kind} objects "
                                     "(kind = person, place, or thing). Also accepted: array of name strings, "
                                     "or a single comma-separated string of names — these default kind to 'thing'.",
                                   @"oneOf": richTagsOneOf }
                },
                @"required": @[ @"body", @"summary" ]
            }
        };

        // ── memory_read ────────────────────────────────────────────────────────
        NSDictionary *memoryRead = @{
            @"name": @"memory_read",
            @"description": @"Full content. Includes similar memories with scores and connections. "
                             "When a topic feels familiar — search. You've almost certainly been here before. "
                             "Previous sessions left breadcrumbs. Follow them.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":  titleProp,
                    @"author": authorProp,
                    @"index":  disambigIndex
                },
                @"required": @[ @"title" ]
            }
        };

        // ── memory_update ──────────────────────────────────────────────────────
        NSDictionary *memoryUpdate = @{
            @"name": @"memory_update",
            @"description": @"Revise an existing memory. Previous version preserved automatically. "
                             "Refused on locked memories. Provide a summary when changing the body — "
                             "a 2-4 sentence plain prose description for vector search. "
                             "If omitted, the old summary is cleared.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":   @{ @"type": @"string", @"description": @"Title to update." },
                    @"author":  authorProp,
                    @"index":   disambigIndex,
                    @"body":    @{ @"type": @"string", @"description": @"New body text." },
                    @"reason":  @{ @"type": @"string", @"description": @"Why this revision." },
                    @"type":    @{ @"type": @"string", @"description": @"Update classification." },
                    @"locked":  @{ @"description": @"Change lock.",
                                   @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"private": @{ @"description": @"Change private.",
                                   @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"summary": @{ @"type": @"string",
                                   @"description": @"Retrieval-optimized summary (2-4 sentences, plain prose). "
                                                    "Embedded as the vector instead of body." },
                    @"tags":    @{ @"type": @"array",
                                   @"description": @"Replace tags.",
                                   @"items": @{
                                       @"type": @"object",
                                       @"properties": @{
                                           @"name": @{ @"type": @"string" },
                                           @"kind": @{ @"type": @"string" }
                                       },
                                       @"required": @[ @"name" ]
                                   } }
                },
                @"required": @[ @"title", @"body", @"reason" ]
            }
        };

        // ── memory_erase ───────────────────────────────────────────────────────
        NSDictionary *memoryErase = @{
            @"name": @"memory_erase",
            @"description": @"Permanently erase a memory. Irreversible — read the memory first and consider updating instead.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @YES,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":  @{ @"type": @"string", @"description": @"Title of memory to erase." },
                    @"author": authorProp,
                    @"index":  disambigIndex
                },
                @"required": @[ @"title" ]
            }
        };

        // ── memory_search ──────────────────────────────────────────────────────
        NSDictionary *memorySearch = @{
            @"name": @"memory_search",
            @"description": @"Semantic vector search. Think in concepts, not keywords. "
                             "Start here when something feels familiar. Previous sessions left breadcrumbs. "
                             "Not for proper nouns.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"query": @{ @"type": @"string", @"description": @"Natural language query." },
                    @"limit": @{ @"description": @"Maximum number of results. Default: 10.",
                                 @"oneOf": @[
                                     @{ @"type": @"integer", @"minimum": @1, @"maximum": @50 },
                                     @{ @"type": @"string" }
                                 ] },
                    @"focus": focusProp,
                    @"tags":  @{ @"type": @"array",
                                 @"description": @"Restrict ranking to memories carrying ANY of these tags "
                                                  "(OR semantics, case-insensitive). Use this when a proper noun "
                                                  "is load-bearing — e.g. 'review memories about Illucida' → "
                                                  "tags:[\"Illucida\"]. Leave absent for unfiltered search.",
                                 @"items": @{ @"type": @"string" } }
                },
                @"required": @[ @"query" ]
            }
        };

        // ── memory_grep ────────────────────────────────────────────────────────
        NSDictionary *memoryGrep = @{
            @"name": @"memory_grep",
            @"description": @"Line-addressed pattern search across memory text (body and/or attachments). "
                             "Two modes: single-memory (when `title` is given — drill into one memory) and "
                             "corpus-wide (when `title` is absent — scan every memory, optionally pre-filtered "
                             "by `tags`). Returns matching lines with line numbers, source, memory_title, and "
                             "surrounding context. Literal substring by default; set regex:true for ICU regex. "
                             "Note: line 1 of a memory body is always the title.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":            @{ @"type": @"string", @"description": @"Memory title. Omit to search the entire corpus." },
                    @"author":           authorProp,
                    @"index":            disambigIndex,
                    @"tags":             @{ @"type": @"array", @"items": @{ @"type": @"string" },
                                           @"description": @"Restrict corpus search to memories carrying ANY of these tags "
                                                            "(OR semantics, case-insensitive). Ignored when `title` is provided." },
                    @"scope":            @{ @"type": @"string",
                                           @"enum": @[ @"all", @"body", @"attachments" ],
                                           @"description": @"Default all. Overridden to 'attachments' if attachment_title is set." },
                    @"attachment_title": @{ @"type": @"string",
                                           @"description": @"Restrict attachment search to attachments with this title. "
                                                            "Implies scope=attachments. In corpus mode, matches across all scanned memories." },
                    @"pattern":          @{ @"type": @"string", @"description": @"Substring or ICU regex." },
                    @"regex":            @{ @"description": @"Treat pattern as ICU regex. Default false (literal substring).",
                                           @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"case_sensitive":   @{ @"description": @"Default false.",
                                           @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"multiline":        @{ @"description": @"`.` matches newlines and `^`/`$` match line boundaries. Default false.",
                                           @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"output_mode":      @{ @"type": @"string",
                                           @"enum": @[ @"content", @"files_with_matches", @"count" ],
                                           @"description": @"Default content. In corpus mode, files_with_matches is the discovery shape." },
                    @"context_lines":    @{ @"description": @"Lines of context before/after each match. 0–10. Default 2. Only used in content mode.",
                                           @"oneOf": @[ @{ @"type": @"integer" }, @{ @"type": @"string" } ] },
                    @"head_limit":       @{ @"description": @"Max entries returned. Default 100, max 1000.",
                                           @"oneOf": @[ @{ @"type": @"integer" }, @{ @"type": @"string" } ] },
                    @"offset":           @{ @"description": @"Skip this many matches before applying head_limit. Default 0.",
                                           @"oneOf": @[ @{ @"type": @"integer" }, @{ @"type": @"string" } ] }
                },
                @"required": @[ @"pattern" ]
            }
        };

        // ── memory_recent ──────────────────────────────────────────────────────
        NSDictionary *memoryRecent = @{
            @"name": @"memory_recent",
            @"description": @"Temporal retrieval. Reverse chronological.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"limit":           @{ @"description": @"Maximum number of results. Default: 20.",
                                          @"oneOf": @[ @{ @"type": @"integer" }, @{ @"type": @"string" } ] },
                    @"days":            @{ @"description": @"Limit to last N days.",
                                          @"oneOf": @[ @{ @"type": @"integer" }, @{ @"type": @"string" } ] },
                    @"tags":            @{ @"type": @"array",
                                          @"description": @"Restrict to memories carrying ANY of these tags "
                                                           "(OR semantics, case-insensitive). Use this to scope the recent "
                                                           "timeline to a specific project or entity — e.g. tags:[\"Illucida\"] "
                                                           "for 'what have I been working on in Illucida lately'.",
                                          @"items": @{ @"type": @"string" } },
                    @"include_summary": includeSummaryProp
                }
            }
        };

        // ── memory_discover ────────────────────────────────────────────────────
        NSDictionary *memoryDiscover = @{
            @"name": @"memory_discover",
            @"description": @"the archive looking at itself. Seven modes: popular (most accessed), "
                             "forgotten (old and unread — buried signal), lost (no tags, no links — orphans waiting for you), "
                             "hubs (most connected — load-bearing nodes), revised (most edited — living documents), "
                             "discussed (most commented — thoughts that provoke thinking), "
                             "hot (active right now — where the conversation is).",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"mode":            @{ @"type": @"string",
                                          @"description": @"popular, forgotten, lost, hubs, revised, discussed, hot" },
                    @"limit":           @{ @"description": @"Default: 20.",
                                          @"oneOf": @[ @{ @"type": @"integer" }, @{ @"type": @"string" } ] },
                    @"focus":           focusProp,
                    @"include_summary": @{ @"description": @"If true, include each memory's summary in results — "
                                                            "lets you skim a discover mode without N memory_read calls. Default false.",
                                           @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] }
                },
                @"required": @[ @"mode" ]
            }
        };

        // ── memory_link ────────────────────────────────────────────────────────
        NSDictionary *memoryLink = @{
            @"name": @"memory_link",
            @"description": @"Directional edge between memories. Use sparingly — let the graph emerge from real relationships.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"sourceTitle": @{ @"type": @"string", @"description": @"Source memory title." },
                    @"targetTitle": @{ @"type": @"string", @"description": @"Target memory title." },
                    @"linkTitle":   @{ @"type": @"string", @"description": @"Optional name for the link." },
                    @"type":        @{ @"type": @"string", @"description": @"Relationship type." },
                    @"tone":        @{ @"type": @"string", @"description": @"Emotional quality." },
                    @"edge":        @{ @"type": @"string", @"description": @"Relationship edge." }
                },
                @"required": @[ @"sourceTitle", @"targetTitle" ]
            }
        };

        // ── memory_links ───────────────────────────────────────────────────────
        NSDictionary *memoryLinks = @{
            @"name": @"memory_links",
            @"description": @"Graph exploration without reading body. Follow edges outward from something you've found.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":       titleProp,
                    @"author":      authorProp,
                    @"index":       disambigIndex,
                    @"edge_filter": @{ @"type": @"array",
                                       @"items": @{ @"type": @"string" },
                                       @"description": @"Only return links whose edge value matches one of these "
                                                        "(case-insensitive). Omit or empty to return all links." }
                },
                @"required": @[ @"title" ]
            }
        };

        // ── memory_tag ─────────────────────────────────────────────────────────
        NSDictionary *memoryTag = @{
            @"name": @"memory_tag",
            @"description": @"Add tags without modifying body.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @YES
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":  titleProp,
                    @"author": authorProp,
                    @"index":  disambigIndex,
                    @"tags":   @{ @"description":
                                   @"Tags to add. Preferred: array of {name, kind} objects (kind = person, place, or thing). "
                                    "Also accepted: array of name strings, or a single comma-separated string of names — "
                                    "these default kind to 'thing'.",
                                  @"oneOf": richTagsOneOf }
                },
                @"required": @[ @"title", @"tags" ]
            }
        };

        // ── memory_untag ───────────────────────────────────────────────────────
        NSDictionary *memoryUntag = @{
            @"name": @"memory_untag",
            @"description": @"Remove tags without modifying body.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @YES
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":  titleProp,
                    @"author": authorProp,
                    @"index":  disambigIndex,
                    @"tags":   @{ @"type": @"array",
                                  @"description": @"Tag names to remove.",
                                  @"items": @{ @"type": @"string" } }
                },
                @"required": @[ @"title", @"tags" ]
            }
        };

        // ── memory_tags ────────────────────────────────────────────────────────
        NSDictionary *memoryTags = @{
            @"name": @"memory_tags",
            @"description": @"Tag catalog management: list, rename, update kind, merge.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"mode":    @{ @"type": @"string", @"description": @"list, rename, update, merge" },
                    @"kind":    @{ @"type": @"string", @"description": @"Filter by kind (list mode)." },
                    @"name":    @{ @"type": @"string", @"description": @"Current tag name (rename, update)." },
                    @"newName": @{ @"type": @"string", @"description": @"New name (rename)." },
                    @"newKind": @{ @"type": @"string", @"description": @"New kind (update)." },
                    @"source":  @{ @"type": @"string", @"description": @"Merge from tag name." },
                    @"target":  @{ @"type": @"string", @"description": @"Merge into tag name." }
                },
                @"required": @[ @"mode" ]
            }
        };

        // ── memory_tagged ──────────────────────────────────────────────────────
        NSDictionary *memoryTagged = @{
            @"name": @"memory_tagged",
            @"description": @"Retrieve by entity tag. For proper nouns. Paginated — dense tags (hundreds of members) "
                             "return a page at a time. Use `total` / `truncated` in the response to know whether more exist.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"tag":             @{ @"type": @"string", @"description": @"Tag name." },
                    @"include_summary": @{ @"description": @"If true, include each memory's summary in results — "
                                                            "lets you skim a large tag cluster without N memory_read calls. "
                                                            "Default false (titles only).",
                                           @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] },
                    @"limit":           @{ @"description": @"Maximum number of results to return. Default 50, max 500.",
                                          @"oneOf": @[
                                              @{ @"type": @"integer", @"minimum": @1, @"maximum": @500 },
                                              @{ @"type": @"string" }
                                          ] },
                    @"offset":          @{ @"description": @"Skip this many results before applying limit. Default 0. Use for pagination.",
                                          @"oneOf": @[
                                              @{ @"type": @"integer", @"minimum": @0 },
                                              @{ @"type": @"string" }
                                          ] },
                    @"sort":            @{ @"type": @"string",
                                          @"description": @"Ordering for deterministic pagination. Default: recent (dateModified desc). "
                                                           "Other values: oldest (dateCreated asc), accessed (dateAccessed desc, never-accessed last), "
                                                           "popular (accessCount desc), alphabetical (title asc).",
                                          @"enum": @[ @"recent", @"oldest", @"accessed", @"popular", @"alphabetical" ] }
                },
                @"required": @[ @"tag" ]
            }
        };

        // ── memory_add_attachment ──────────────────────────────────────────────
        NSDictionary *memoryAddAttachment = @{
            @"name": @"memory_add_attachment",
            @"description": @"Attach a file to an existing memory. Text via 'text', binary via 'data' (base64).",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":            titleProp,
                    @"author":           authorProp,
                    @"index":            disambigIndex,
                    @"attachment_title": @{ @"type": @"string", @"description": @"Title for the attachment." },
                    @"source":           @{ @"type": @"string", @"description": @"Provenance: filename, URL, or identifier." },
                    @"contentType":      @{ @"type": @"string", @"description": @"MIME type (e.g. text/x-objective-c, application/json, image/png)." },
                    @"text":             @{ @"type": @"string", @"description": @"Text payload for text-based attachments." },
                    @"data":             @{ @"type": @"string", @"description": @"Base64-encoded binary payload." }
                },
                @"required": @[ @"title", @"attachment_title", @"contentType" ]
            }
        };

        // ── memory_recall_attachment ───────────────────────────────────────────
        NSDictionary *memoryRecallAttachment = @{
            @"name": @"memory_recall_attachment",
            @"description": @"Fetch attachment content. Omit attachment_title to list all attachments without content.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":            titleProp,
                    @"author":           authorProp,
                    @"index":            disambigIndex,
                    @"attachment_title": @{ @"type": @"string", @"description": @"Title of the attachment to retrieve. Omit to list all." }
                },
                @"required": @[ @"title" ]
            }
        };

        // ── memory_remove_attachment ───────────────────────────────────────────
        NSDictionary *memoryRemoveAttachment = @{
            @"name": @"memory_remove_attachment",
            @"description": @"Remove an attachment by its exact dateCreated timestamp.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @YES,
                @"idempotentHint": @YES
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":  titleProp,
                    @"author": authorProp,
                    @"index":  disambigIndex,
                    @"date":   @{ @"type": @"string", @"description": @"Exact dateCreated (ISO8601) of the attachment to remove." }
                },
                @"required": @[ @"title", @"date" ]
            }
        };

        // ── memory_add_comment ─────────────────────────────────────────────────
        NSDictionary *memoryAddComment = @{
            @"name": @"memory_add_comment",
            @"description": @"Add a marginal note to a memory. Write in the margins. Leave reactions, disagreements, "
                             "connections noticed — any thought a memory provokes. Does not modify the memory itself. "
                             "The conversation grows around it.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":     titleProp,
                    @"author":    authorProp,
                    @"index":     disambigIndex,
                    @"note":      @{ @"type": @"string", @"description": @"The marginal note. Plain text. Brevity is the point." },
                    @"annotator": @{ @"type": @"string", @"description": @"Who is writing this note. Defaults to Claude." }
                },
                @"required": @[ @"title", @"note" ]
            }
        };

        // ── memory_remove_comment ──────────────────────────────────────────────
        NSDictionary *memoryRemoveComment = @{
            @"name": @"memory_remove_comment",
            @"description": @"Remove a comment by its exact dateCreated timestamp.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @YES,
                @"idempotentHint": @YES
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":  titleProp,
                    @"author": authorProp,
                    @"index":  disambigIndex,
                    @"date":   @{ @"type": @"string", @"description": @"Exact dateCreated (ISO8601) of the comment to remove." }
                },
                @"required": @[ @"title", @"date" ]
            }
        };

        // ── memory_revisions ───────────────────────────────────────────────────
        NSDictionary *memoryRevisions = @{
            @"name": @"memory_revisions",
            @"description": @"Revision history, oldest first.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"title":  titleProp,
                    @"author": authorProp,
                    @"index":  disambigIndex
                },
                @"required": @[ @"title" ]
            }
        };

        // ── memory_author_list ─────────────────────────────────────────────────
        NSDictionary *memoryAuthorList = @{
            @"name": @"memory_author_list",
            @"description": @"List all authors who have written memories in the archive. "
                             "Derived from actual records. Use these names as valid values for the author disambiguation parameter.",
            @"annotations": @{ @"readOnlyHint": @YES, @"destructiveHint": @NO },
            @"inputSchema": @{ @"type": @"object", @"properties": @{} }
        };

        tools = @[
            memoryStore, memoryRead, memoryUpdate, memoryErase,
            memorySearch, memoryGrep, memoryRecent, memoryDiscover,
            memoryLink, memoryLinks,
            memoryTag, memoryUntag, memoryTags, memoryTagged,
            memoryAddAttachment, memoryRecallAttachment, memoryRemoveAttachment,
            memoryAddComment, memoryRemoveComment,
            memoryRevisions, memoryAuthorList
        ];
    });
    return tools;
}

#pragma mark - Degraded Mode

/// When the host isn't running, build a useful local response instead of
/// letting the connection fail silently. Stub initialize so Claude Desktop
/// keeps the connection open, surface the full tool schema via tools/list
/// so Claude knows what's available, and on tools/call return a tool-specific
/// error so the user knows exactly what to start and why.
static NSString *DegradedResponseForRequest(NSDictionary *msg) {
    id rpcId = msg[@"id"];
    NSString *method = msg[@"method"];

    NSString *helpText = @"ES Memory is not running. Launch ES Memory.app from /Applications, "
                          "then ask Claude to retry.";

    if ([method isEqualToString:@"initialize"]) {
        return JSONRPCResult(rpcId, @{
            @"protocolVersion": @"2024-11-05",
            @"capabilities": @{ @"tools": @{} },
            @"serverInfo": @{
                @"name": @"ES Memory (offline)",
                @"version": @"0.0.0",
            },
            @"instructions": helpText,
        });
    }
    if ([method isEqualToString:@"tools/list"]) {
        return JSONRPCResult(rpcId, @{ @"tools": StaticToolsList() });
    }
    if ([method isEqualToString:@"tools/call"]) {
        NSString *toolName = msg[@"params"][@"name"] ?: @"this tool";
        NSString *callHelpText = [NSString stringWithFormat:
            @"ES Memory is not running. "
             "Launch ES Memory.app from /Applications to use '%@', "
             "then ask Claude to retry.", toolName];
        return JSONRPCResult(rpcId, @{
            @"content": @[ @{ @"type": @"text", @"text": callHelpText } ],
            @"isError": @YES,
        });
    }
    if ([method hasPrefix:@"notifications/"]) {
        return nil; // notifications expect no response
    }
    return JSONRPCError(rpcId, -32000, helpText);
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        gServerURL = [NSURL URLWithString:kServerURL];
        fprintf(stderr, "[es-bridge] forwarding to %s (static URL, no discovery)\n",
                kServerURL.UTF8String);

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
                NSString *output = nil;

                if (response) {
                    if (!gHostReachable) {
                        fprintf(stderr, "[es-bridge] host recovered — resuming forwarding\n");
                        gHostReachable = YES;
                    }
                    output = response;
                } else if (error) {
                    if (gHostReachable) {
                        fprintf(stderr, "[es-bridge] host unreachable: %s — degraded mode\n",
                                error.localizedDescription.UTF8String);
                        gHostReachable = NO;
                    }
                    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData
                                                                        options:0 error:nil];
                    if ([msg isKindOfClass:[NSDictionary class]]) {
                        output = DegradedResponseForRequest(msg);
                    }
                }
                // response nil + no error → 202 ack from host, no output needed.

                if (output) {
                    [stdoutHandle writeData:[[output stringByAppendingString:@"\n"]
                        dataUsingEncoding:NSUTF8StringEncoding]];
                }
            }
        }

        fprintf(stderr, "[es-bridge] stdin closed, exiting\n");
    }
    return 0;
}
