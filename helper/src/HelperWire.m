#import "HelperWire.h"

@implementation HelperRequest
@end

@implementation HelperResponse
+ (instancetype)okWithId:(NSString *)reqId chatGuid:(NSString *)chatGuid {
    HelperResponse *r = [HelperResponse new];
    r.v = 1; r.reqId = reqId; r.ok = YES; r.chatGuid = chatGuid;
    return r;
}
+ (instancetype)errorWithId:(NSString *)reqId code:(NSString *)code message:(NSString *)message {
    HelperResponse *r = [HelperResponse new];
    r.v = 1; r.reqId = reqId; r.ok = NO; r.errorCode = code; r.errorMessage = message;
    return r;
}
@end

@implementation HelperWire

+ (HelperRequest *)decodeRequestLine:(NSData *)line error:(NSString **)errId {
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (errId) { *errId = @""; }
        return nil;
    }
    HelperRequest *req = [HelperRequest new];
    req.v = [obj[@"v"] isKindOfClass:[NSNumber class]] ? [obj[@"v"] integerValue] : 0;
    req.reqId = [obj[@"id"] isKindOfClass:[NSString class]] ? obj[@"id"] : @"";
    req.cmd = [obj[@"cmd"] isKindOfClass:[NSString class]] ? obj[@"cmd"] : @"";
    req.addresses = [obj[@"addresses"] isKindOfClass:[NSArray class]] ? obj[@"addresses"] : nil;
    req.service = [obj[@"service"] isKindOfClass:[NSString class]] ? obj[@"service"] : nil;
    req.chatGuid = [obj[@"chat_guid"] isKindOfClass:[NSString class]] ? obj[@"chat_guid"] : nil;
    req.body = [obj[@"body"] isKindOfClass:[NSString class]] ? obj[@"body"] : nil;
    req.path = [obj[@"path"] isKindOfClass:[NSString class]] ? obj[@"path"] : nil;
    return req;
}

+ (NSData *)encodeResponse:(HelperResponse *)resp {
    NSMutableDictionary *obj = [@{ @"v": @(resp.v), @"id": resp.reqId ?: @"", @"ok": @(resp.ok) } mutableCopy];
    if (resp.chatGuid) { obj[@"chat_guid"] = resp.chatGuid; }
    if (!resp.ok) {
        obj[@"error"] = @{ @"code": resp.errorCode ?: @"unknown",
                           @"message": resp.errorMessage ?: @"" };
    }
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    return data;
}

@end
