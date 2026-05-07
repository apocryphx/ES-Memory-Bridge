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
#import "ESBridgeCLI.h"
#include <signal.h>

static NSString *const kServerURL = @"http://localhost:59123/mcp";

static NSURL *gServerURL = nil;
static BOOL  gHostReachable = YES; // optimism; flipped on first forward failure

#pragma mark - HTTP Forwarding

// Non-static — called from ESBridgeCLI when handling memory_cli pipelines.
NSString *ForwardRequest(NSString *jsonLine, NSError **outError) {
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
                    @"language": @{ @"type": @"string",
                                    @"description": @"ISO 639-1 language code ('en', 'de', 'fr', 'ja', etc.). "
                                                     "Optional. If omitted, defaults to your working content language "
                                                     "(English unless changed via memory_settings). Set explicitly only "
                                                     "when this memory's primary language differs from your current "
                                                     "default — e.g. you wrote a German letter but normally work in English." },
                    @"tags":    @{ @"description":
                                    @"Tags to attach. Each tag must already exist — create with memory_create_tag(name, kind) "
                                     "first. Pass an array of {name} or {name, kind} objects, an array of name strings, or a "
                                     "comma-separated string. Unknown names are reported as an error and the memory is not stored.",
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
                    @"language": @{ @"type": @"string",
                                    @"description": @"ISO 639-1 language code of the updated memory ('en', 'de', etc.). "
                                                     "Optional. If omitted, the memory's existing language tag is preserved. "
                                                     "Set explicitly only when you're actually changing the language of the "
                                                     "memory's primary content." },
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

        // ── memory_cli ─────────────────────────────────────────────────────────
        // The unified search surface. Subsumes the server's memory_search,
        // memory_grep, memory_recent, memory_tagged, memory_discover. Bridge
        // parses the pipeline expression and dispatches to those server tools
        // internally. Try memory_cli("man") to see the command vocabulary.
        NSDictionary *memoryCLI = @{
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
            @"description": @"Attach existing tags to a memory. Tags are deliberate, authored objects — "
                             "they must already exist. Create with memory_create_tag(name, kind) first. "
                             "Unknown names are reported as an error and nothing is attached.",
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
                                   @"Names of existing tags to attach. Preferred: array of {name} objects. "
                                    "Also accepted: array of strings, or a single comma-separated string. "
                                    "Tags must exist via memory_create_tag.",
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
            @"description": @"Tag catalog management: list, rename, update kind, merge. "
                             "List output includes dateCreated and dateExpired; expired tags are hidden by default.",
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
                    @"name":    @{ @"type": @"string", @"description": @"In list mode: case-insensitive substring filter "
                                                                        "(e.g. \"Hu\" matches Humboldt, Hundertwasser). "
                                                                        "In rename/update: exact tag name to modify." },
                    @"limit":   @{ @"type": @"integer", @"description": @"Maximum tags to return (list mode). Default 50." },
                    @"offset":  @{ @"type": @"integer", @"description": @"Skip this many tags before applying limit (list mode). Default 0." },
                    @"newName": @{ @"type": @"string", @"description": @"New name (rename)." },
                    @"newKind": @{ @"type": @"string", @"description": @"New kind (update)." },
                    @"source":  @{ @"type": @"string", @"description": @"Merge from tag name." },
                    @"target":  @{ @"type": @"string", @"description": @"Merge into tag name." },
                    @"includeExpired": @{ @"description": @"List mode: include tags whose dateExpired has passed. Default false.",
                                          @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ] }
                },
                @"required": @[ @"mode" ]
            }
        };

        // ── memory_create_tag ──────────────────────────────────────────────────
        NSDictionary *memoryCreateTag = @{
            @"name": @"memory_create_tag",
            @"description":
                @"Create a new tag. Tags are curated, deliberate handles — there is no "
                 "auto-creation anywhere else, so every tag's existence is an explicit "
                 "authored gesture. `kind` is descriptive metadata. Canonical kinds: "
                 "person, place, project, principle, subset, session, research. "
                 "`expiresAt` is optional; absent or null = permanent. The tag is "
                 "created with no memory associations — use memory_tag to attach a "
                 "specific memory, or `... | tag NAME` in memory_cli to attach a "
                 "search-result population in one atomic gesture.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @NO
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"name": @{ @"type": @"string",
                                @"description": @"Tag name. Case-insensitive uniqueness." },
                    @"kind": @{ @"type": @"string",
                                @"description": @"Descriptive kind: person, place, project, principle, subset, session, research." },
                    @"expiresAt": @{
                        @"description": @"ISO-8601 absolute datetime (e.g. 2026-06-01T12:00:00Z) or relative "
                                         "offset (e.g. \"+30 days\", \"-1 hour\", \"+2h\"). Omit or null for permanent.",
                        @"oneOf": @[ @{ @"type": @"string" }, @{ @"type": @"null" } ]
                    }
                },
                @"required": @[ @"name", @"kind" ]
            }
        };

        // ── memory_delete_tag ──────────────────────────────────────────────────
        NSDictionary *memoryDeleteTag = @{
            @"name": @"memory_delete_tag",
            @"description":
                @"Delete a tag and all its memory associations. The memories themselves are "
                 "not touched — only the tag-to-memory edges are removed. Irreversible.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @YES,
                @"idempotentHint": @YES
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"name": @{ @"type": @"string",
                                @"description": @"Tag name to delete (case-insensitive)." }
                },
                @"required": @[ @"name" ]
            }
        };

        // ── memory_extend_tag ──────────────────────────────────────────────────
        NSDictionary *memoryExtendTag = @{
            @"name": @"memory_extend_tag",
            @"description":
                @"Update the expiration of an existing tag. Pass `newExpiresAt` as ISO-8601 "
                 "or a relative offset to set a new expiration; pass null to make the tag "
                 "permanent. Useful for keeping a session/research tag alive past its "
                 "original window when work continues.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                @"destructiveHint": @NO,
                @"idempotentHint": @YES
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"name": @{ @"type": @"string",
                                @"description": @"Tag name (case-insensitive)." },
                    @"newExpiresAt": @{
                        @"description": @"ISO-8601 absolute datetime, relative offset (\"+30 days\"), or null to clear.",
                        @"oneOf": @[ @{ @"type": @"string" }, @{ @"type": @"null" } ]
                    }
                },
                @"required": @[ @"name" ]
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

        // ── memory_maintenance ─────────────────────────────────────────────────
        // Claude's control panel for the archive. Three concerns in one tool:
        // settings (persistent preferences), actions (bulk operations), status
        // (live diagnostics). Per-call knobs like search focus / decayLevel are
        // intentionally NOT settings — they're parameters on the relevant tool,
        // so each session decides them explicitly rather than inheriting
        // invisible state from a previous session.
        NSDictionary *memoryMaintenance = @{
            @"name": @"memory_maintenance",
            @"description":
                @"Claude's control panel for the archive. Three concerns in one surface:\n\n"
                 "1. SETTINGS — persistent working preferences. Set via top-level fields. "
                 "Currently: 'language' (ISO 639-1 default for new memories and queries) "
                 "and 'embedder' (preferred vector embedder, or 'auto' to clear preference). "
                 "Only things that *should* be inherited by the next session live here — "
                 "per-call knobs like search focus / decayLevel are NOT settings; they're "
                 "parameters on the relevant tool, so each session decides them explicitly.\n\n"
                 "2. ACTIONS — bulk operations on the archive. Set via 'action' field. "
                 "Available: 'reindex' (rebuild every vector with the active embedder — "
                 "expensive, runs in background), 'backfill' (generate vectors only for "
                 "memories that lack one — cheap, additive), 'purge_empty' (permanently "
                 "erase memories with no body AND no summary, skipping locked memories — "
                 "irreversible; reports deleted count and titles), 'dump_defects' (write "
                 "every memory matching defect predicates to a temp file (path returned in the response) so "
                 "Claude can read and triage them before any destructive action). 'reindex' "
                 "and 'backfill' return immediately with status 'started'; 'purge_empty' and "
                 "'dump_defects' complete synchronously.\n\n"
                 "3. STATUS — called with no parameters, returns current settings, available "
                 "embedders, archive counts (memories, vectors, missing-vectors), and pending "
                 "work. The same status block is also returned after every settings change "
                 "or action trigger, so one call always tells you the full picture.",
            @"annotations": @{
                @"readOnlyHint": @NO,
                // Destructive when action='purge_empty' (permanent deletion of
                // empty memories). Other paths are non-destructive. The hint
                // is an upper bound on capability, hence YES.
                @"destructiveHint": @YES,
                @"idempotentHint": @YES
            },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"language": @{
                        @"type": @"string",
                        @"description": @"ISO 639-1 code ('en', 'de', 'fr', 'ja', etc.). Becomes the "
                                         "default language for memory_store and memory_update when no "
                                         "per-call language is given."
                    },
                    @"embedder": @{
                        @"type": @"string",
                        @"description": @"Identifier of a registered embedder (see 'availableEmbedders' "
                                         "in the response). Pass 'auto' to clear the explicit preference "
                                         "and fall back to the cold-start heuristic."
                    },
                    @"resetHeuristic": @{
                        @"description": @"If true, clears the cached cold-start heuristic embedder choice "
                                         "so it re-runs on next encode. Use after substantial archive growth "
                                         "in a previously-rare language. Default: false.",
                        @"oneOf": @[ @{ @"type": @"boolean" }, @{ @"type": @"string" } ]
                    },
                    @"action": @{
                        @"type": @"string",
                        @"description": @"Trigger a bulk operation. 'reindex' = rebuild every vector with "
                                         "the active embedder (expensive — only after switching embedder, "
                                         "or to repair systemic vector drift; runs in background). "
                                         "'backfill' = generate vectors only for memories that lack one "
                                         "(cheap, safe to run anytime; runs in background). 'purge_empty' "
                                         "= permanently erase memories with no body AND no summary, "
                                         "skipping locked memories (irreversible; completes synchronously "
                                         "and reports the deleted count + titles). 'dump_defects' = write "
                                         "every memory matching defect predicates to a temp file (path returned in the response) "
                                         "so Claude can read and triage them before any destructive action. "
                                         "After background actions, re-call with no arguments to see "
                                         "progress via 'pendingVectorOperations'.",
                        @"enum": @[ @"reindex", @"backfill", @"purge_empty", @"dump_defects" ]
                    }
                },
                @"required": @[]
            }
        };

        tools = @[
            memoryCLI,
            memoryStore, memoryRead, memoryUpdate, memoryErase,
            memoryLink, memoryLinks,
            memoryTag, memoryUntag, memoryTags,
            memoryCreateTag, memoryDeleteTag, memoryExtendTag,
            memoryAddAttachment, memoryRecallAttachment, memoryRemoveAttachment,
            memoryAddComment, memoryRemoveComment,
            memoryRevisions, memoryAuthorList,
            memoryMaintenance
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

                // Parse the JSON-RPC request once so we can dispatch on method
                // and tool name. Bridge intercepts:
                //   - tools/list: always served from our filtered static schema
                //     (the bridge presents memory_cli + non-search tools as the
                //     Claude-facing surface; the server's per-tool search surface
                //     is hidden behind memory_cli).
                //   - tools/call(memory_cli): handled locally by ESBridgeCLI,
                //     which makes its own HTTP calls to the server's per-tool
                //     surface as composition requires.
                //   - everything else: forwarded transparently.
                NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData
                                                                    options:0 error:nil];
                NSString *output = nil;

                if ([msg isKindOfClass:[NSDictionary class]]) {
                    NSString *method = msg[@"method"];
                    id rpcId = msg[@"id"];

                    if ([method isEqualToString:@"tools/list"]) {
                        // Always serve our filtered static schema, even when
                        // the host is up. The bridge IS the curated surface.
                        output = JSONRPCResult(rpcId, @{ @"tools": StaticToolsList() });
                    } else if ([method isEqualToString:@"tools/call"]) {
                        NSString *toolName = msg[@"params"][@"name"];

                        // Pre-normalize relative-date args ("+30 days") into
                        // ISO-8601 before forwarding. Server tools accept
                        // strict ISO-8601; this lets Claude write ergonomically.
                        // If normalization fails, error locally instead of
                        // forwarding garbage.
                        NSString *dateKey = nil;
                        if ([toolName isEqualToString:@"memory_create_tag"]) dateKey = @"expiresAt";
                        else if ([toolName isEqualToString:@"memory_extend_tag"]) dateKey = @"newExpiresAt";
                        if (dateKey) {
                            id raw = msg[@"params"][@"arguments"][dateKey];
                            if ([raw isKindOfClass:NSString.class] && [(NSString *)raw length] > 0) {
                                NSString *normalized = ESBridgeNormalizeRelativeDate(raw);
                                if (!normalized) {
                                    output = JSONRPCError(rpcId, -32602,
                                        [NSString stringWithFormat:
                                            @"%@: '%@' is not a valid date. "
                                             "Pass ISO-8601 (e.g. 2026-06-01T12:00:00Z) or a relative "
                                             "offset like \"+30 days\", \"-1 hour\", \"+2h\".",
                                            dateKey, raw]);
                                } else if (![raw isEqualToString:normalized]) {
                                    // Rewrite the line so the unified
                                    // ForwardRequest below sends the
                                    // normalized timestamp.
                                    NSMutableDictionary *newArgs = [msg[@"params"][@"arguments"] mutableCopy]
                                        ?: [NSMutableDictionary dictionary];
                                    newArgs[dateKey] = normalized;
                                    NSMutableDictionary *newParams = [msg[@"params"] mutableCopy];
                                    newParams[@"arguments"] = newArgs;
                                    NSMutableDictionary *newMsg = [msg mutableCopy];
                                    newMsg[@"params"] = newParams;
                                    NSData *encoded = [NSJSONSerialization
                                        dataWithJSONObject:newMsg options:0 error:nil];
                                    if (encoded) {
                                        line = [[NSString alloc] initWithData:encoded
                                                                     encoding:NSUTF8StringEncoding];
                                        msg  = newMsg; // keep msg in sync for degraded path
                                    }
                                }
                            }
                        }

                        if ([toolName isEqualToString:@"memory_cli"]) {
                            // Handle locally. The CLI executor will make its
                            // own HTTP calls to the server's per-tool surface.
                            NSString *expression = msg[@"params"][@"arguments"][@"expression"];
                            if (![expression isKindOfClass:[NSString class]] || expression.length == 0) {
                                output = JSONRPCError(rpcId, -32602,
                                    @"`expression` is required. Try memory_cli(\"man\") to see commands.");
                            } else {
                                NSError *parseErr = nil;
                                NSArray *tokens = ESBridgeCLITokenize(expression, &parseErr);
                                NSDictionary *result = nil;
                                if (!tokens) {
                                    result = @{
                                        @"error":      @"parse_error",
                                        @"message":    parseErr.localizedDescription ?: @"could not tokenize",
                                        @"expression": expression,
                                    };
                                } else {
                                    NSArray *stages = ESBridgeCLIParseStages(tokens, &parseErr);
                                    if (!stages) {
                                        result = @{
                                            @"error":      @"parse_error",
                                            @"message":    parseErr.localizedDescription ?: @"could not parse",
                                            @"expression": expression,
                                        };
                                    } else {
                                        result = ESBridgeCLIExecute(stages);
                                    }
                                }
                                NSData *resultData = [NSJSONSerialization
                                    dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
                                NSString *resultText = resultData
                                    ? [[NSString alloc] initWithData:resultData encoding:NSUTF8StringEncoding]
                                    : @"{}";
                                output = JSONRPCResult(rpcId, @{
                                    @"content": @[ @{
                                        @"type": @"text",
                                        @"text": resultText
                                    } ]
                                });
                            }
                        }
                    }
                }

                // Fall through to forwarding for anything we didn't handle.
                if (!output) {
                    NSError *error = nil;
                    NSString *response = ForwardRequest(line, &error);

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
                        if ([msg isKindOfClass:[NSDictionary class]]) {
                            output = DegradedResponseForRequest(msg);
                        }
                    }
                    // response nil + no error → 202 ack from host, no output.
                }

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
