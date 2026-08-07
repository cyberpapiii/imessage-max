#import <XCTest/XCTest.h>
#import <sys/socket.h>
#import <unistd.h>
#import "HelperListener.h"
#import "HelperDispatcher.h"
#import "IMCoreFacade.h"

@interface EchoFacade : NSObject <IMCoreFacade>
@end
@implementation EchoFacade
- (NSString *)createChatWithAddresses:(NSArray<NSString *> *)a service:(NSString *)s error:(NSString **)e { return @"iMessage;+;made"; }
- (BOOL)sendText:(NSString *)b toChatGuid:(NSString *)g error:(NSString **)e { return YES; }
- (BOOL)sendFileAtPath:(NSString *)p toChatGuid:(NSString *)g error:(NSString **)e { return YES; }
@end

@interface HelperListenerTests : XCTestCase
@end

@implementation HelperListenerTests

- (void)testServeConnectionHandlesOneRequest {
    int fds[2];
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);
    int clientFD = fds[0], serverFD = fds[1];

    HelperDispatcher *disp = [[HelperDispatcher alloc] initWithFacade:[EchoFacade new]];
    HelperListener *listener = [[HelperListener alloc] initWithDispatcher:disp];

    // Server side on a background thread.
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [listener serveConnectionFD:serverFD];
        close(serverFD);
    });

    // Client writes one create-chat request line.
    const char *req = "{\"v\":1,\"id\":\"7\",\"cmd\":\"create-chat\",\"addresses\":[\"+1\",\"+2\"]}\n";
    write(clientFD, req, strlen(req));

    // Read one response line.
    char buf[512]; ssize_t n = read(clientFD, buf, sizeof(buf) - 1);
    XCTAssertGreaterThan(n, 0);
    buf[n] = 0;
    NSString *resp = [NSString stringWithUTF8String:buf];
    XCTAssertTrue([resp containsString:@"\"ok\":true"]);
    XCTAssertTrue([resp containsString:@"iMessage;+;made"]);
    XCTAssertTrue([resp containsString:@"\"id\":\"7\""]);
    XCTAssertTrue([resp hasSuffix:@"\n"]);
    close(clientFD);
}

- (void)testResolveSocketPathHonorsEnv {
    setenv("IMESSAGE_MAX_HELPER_SOCKET", "/tmp/custom-helper.sock", 1);
    XCTAssertEqualObjects([HelperListener resolveSocketPath], @"/tmp/custom-helper.sock");
    unsetenv("IMESSAGE_MAX_HELPER_SOCKET");
    XCTAssertTrue([[HelperListener resolveSocketPath] hasSuffix:@"imessage-max-helper.sock"]);
}

@end
