//
//  AppDelegate.m
//  ES-Memory-Bridge
//

#import "AppDelegate.h"
#import "SchemaCache.h"
#import "Forwarder.h"
#import "MCPServer.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    fprintf(stderr, "[es-bridge] applicationDidFinishLaunching\n");

    // Touch the shared Forwarder once so its init log line lands before
    // the first inbound line — keeps the log ordering stable.
    (void)[Forwarder shared];

    // Load schema synchronously so the very first tools/list won't race the
    // cache load. nil fallback — the .app bundle ships
    // Resources/tools-bootstrap.json as the cold-start fallback.
    [[SchemaCache shared] loadOnStartupWithFallback:nil];

    [[MCPServer shared] start];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)note {
    fprintf(stderr, "[es-bridge] applicationWillTerminate\n");
}

@end
