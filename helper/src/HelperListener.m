#import "HelperListener.h"
#import "HelperWire.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

@implementation HelperListener {
    HelperDispatcher *_dispatcher;
    int _listenFD;
}

- (instancetype)initWithDispatcher:(HelperDispatcher *)dispatcher {
    if ((self = [super init])) { _dispatcher = dispatcher; _listenFD = -1; }
    return self;
}

+ (NSString *)resolveSocketPath {
    const char *env = getenv("IMESSAGE_MAX_HELPER_SOCKET");
    if (env && env[0]) { return [NSString stringWithUTF8String:env]; }
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"imessage-max-helper.sock"];
}

- (void)serveConnectionFD:(int)fd {
    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    while (YES) {
        // Drain any complete lines already buffered.
        NSRange nl;
        while ((nl = [self rangeOfNewlineIn:buf]).location != NSNotFound) {
            NSData *line = [buf subdataWithRange:NSMakeRange(0, nl.location)];
            [buf replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
            NSString *errId = nil;
            HelperRequest *req = [HelperWire decodeRequestLine:line error:&errId];
            HelperResponse *resp = req
                ? [_dispatcher handle:req]
                : [HelperResponse errorWithId:(errId ?: @"") code:@"malformed_request" message:@"invalid JSON line"];
            NSData *out = [HelperWire encodeResponse:resp];
            write(fd, out.bytes, out.length);
        }
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) { break; }
        [buf appendBytes:chunk length:(NSUInteger)n];
    }
}

- (NSRange)rangeOfNewlineIn:(NSData *)data {
    const char nl = '\n';
    return [data rangeOfData:[NSData dataWithBytes:&nl length:1]
                     options:0 range:NSMakeRange(0, data.length)];
}

- (BOOL)bindAndListenAtPath:(NSString *)path error:(NSString **)err {
    unlink(path.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { if (err) { *err = @"socket() failed"; } return NO; }
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd); if (err) { *err = @"bind() failed"; } return NO;
    }
    if (listen(fd, 4) != 0) {
        close(fd); if (err) { *err = @"listen() failed"; } return NO;
    }
    _listenFD = fd;
    return YES;
}

- (void)acceptLoop {
    while (_listenFD >= 0) {
        int conn = accept(_listenFD, NULL, NULL);
        if (conn < 0) { continue; }
        [self serveConnectionFD:conn];
        close(conn);
    }
}

@end
