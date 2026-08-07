#import "HelperDispatcher.h"

@implementation HelperDispatcher {
    id<IMCoreFacade> _facade;
}

- (instancetype)initWithFacade:(id<IMCoreFacade>)facade {
    if ((self = [super init])) { _facade = facade; }
    return self;
}

- (HelperResponse *)handle:(HelperRequest *)req {
    if (req.v != 1) {
        return [HelperResponse errorWithId:req.reqId code:@"protocol_mismatch"
                                   message:[NSString stringWithFormat:@"expected v=1, got %ld", (long)req.v]];
    }
    NSString *errCode = nil;

    if ([req.cmd isEqualToString:@"ping"]) {
        return [HelperResponse okWithId:req.reqId chatGuid:nil];
    }
    if ([req.cmd isEqualToString:@"create-chat"]) {
        if (req.addresses.count == 0) {
            return [HelperResponse errorWithId:req.reqId code:@"invalid_request"
                                       message:@"create-chat requires non-empty addresses"];
        }
        NSString *guid = [_facade createChatWithAddresses:req.addresses
                                                  service:req.service ?: @"iMessage"
                                                    error:&errCode];
        if (!guid) {
            return [HelperResponse errorWithId:req.reqId code:(errCode ?: @"create_failed") message:@"create-chat failed"];
        }
        return [HelperResponse okWithId:req.reqId chatGuid:guid];
    }
    if ([req.cmd isEqualToString:@"send-text"]) {
        if (req.chatGuid.length == 0 || req.body == nil) {
            return [HelperResponse errorWithId:req.reqId code:@"invalid_request"
                                       message:@"send-text requires chat_guid and body"];
        }
        BOOL ok = [_facade sendText:req.body toChatGuid:req.chatGuid error:&errCode];
        return ok ? [HelperResponse okWithId:req.reqId chatGuid:nil]
                  : [HelperResponse errorWithId:req.reqId code:(errCode ?: @"send_failed") message:@"send-text failed"];
    }
    if ([req.cmd isEqualToString:@"send-file"]) {
        if (req.chatGuid.length == 0 || req.path.length == 0) {
            return [HelperResponse errorWithId:req.reqId code:@"invalid_request"
                                       message:@"send-file requires chat_guid and path"];
        }
        BOOL ok = [_facade sendFileAtPath:req.path toChatGuid:req.chatGuid error:&errCode];
        return ok ? [HelperResponse okWithId:req.reqId chatGuid:nil]
                  : [HelperResponse errorWithId:req.reqId code:(errCode ?: @"send_failed") message:@"send-file failed"];
    }
    return [HelperResponse errorWithId:req.reqId code:@"unknown_command"
                               message:[NSString stringWithFormat:@"unknown cmd: %@", req.cmd]];
}

@end
