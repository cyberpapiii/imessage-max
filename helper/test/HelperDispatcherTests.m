#import <XCTest/XCTest.h>
#import "HelperDispatcher.h"
#import "IMCoreFacade.h"
#import "HelperWire.h"

@interface StubFacade : NSObject <IMCoreFacade>
@property (nonatomic, copy) NSString *guidToReturn;   // nil => failure
@property (nonatomic, copy) NSString *failCode;       // used when guidToReturn nil / send fails
@property (nonatomic) BOOL sendSucceeds;
@property (nonatomic, copy) NSArray<NSString *> *lastAddresses;
@property (nonatomic, copy) NSString *lastBody;
@end

@implementation StubFacade
- (NSString *)createChatWithAddresses:(NSArray<NSString *> *)addresses service:(NSString *)service error:(NSString **)errCode {
    self.lastAddresses = addresses;
    if (self.guidToReturn) { return self.guidToReturn; }
    if (errCode) { *errCode = self.failCode ?: @"handle_not_found"; }
    return nil;
}
- (BOOL)sendText:(NSString *)body toChatGuid:(NSString *)guid error:(NSString **)errCode {
    self.lastBody = body;
    if (!self.sendSucceeds && errCode) { *errCode = self.failCode ?: @"send_failed"; }
    return self.sendSucceeds;
}
- (BOOL)sendFileAtPath:(NSString *)path toChatGuid:(NSString *)guid error:(NSString **)errCode {
    if (!self.sendSucceeds && errCode) { *errCode = self.failCode ?: @"send_failed"; }
    return self.sendSucceeds;
}
@end

@interface HelperDispatcherTests : XCTestCase
@end

@implementation HelperDispatcherTests

- (HelperRequest *)reqWithId:(NSString *)i cmd:(NSString *)c {
    HelperRequest *r = [HelperRequest new]; r.v = 1; r.reqId = i; r.cmd = c; return r;
}

- (void)testCreateChatSuccessReturnsGuid {
    StubFacade *f = [StubFacade new]; f.guidToReturn = @"iMessage;+;g";
    HelperDispatcher *d = [[HelperDispatcher alloc] initWithFacade:f];
    HelperRequest *req = [self reqWithId:@"1" cmd:@"create-chat"];
    req.addresses = @[@"+1", @"+2"]; req.service = @"iMessage";
    HelperResponse *resp = [d handle:req];
    XCTAssertTrue(resp.ok);
    XCTAssertEqualObjects(resp.chatGuid, @"iMessage;+;g");
    XCTAssertEqualObjects(f.lastAddresses, (@[@"+1", @"+2"]));
}

- (void)testCreateChatFacadeFailureSurfacesCode {
    StubFacade *f = [StubFacade new]; f.guidToReturn = nil; f.failCode = @"handle_not_found";
    HelperDispatcher *d = [[HelperDispatcher alloc] initWithFacade:f];
    HelperRequest *req = [self reqWithId:@"1" cmd:@"create-chat"];
    req.addresses = @[@"+1"];
    HelperResponse *resp = [d handle:req];
    XCTAssertFalse(resp.ok);
    XCTAssertEqualObjects(resp.errorCode, @"handle_not_found");
}

- (void)testCreateChatEmptyAddressesRejectedWithoutCallingFacade {
    StubFacade *f = [StubFacade new]; f.guidToReturn = @"should-not-be-used";
    HelperDispatcher *d = [[HelperDispatcher alloc] initWithFacade:f];
    HelperRequest *req = [self reqWithId:@"1" cmd:@"create-chat"];
    req.addresses = @[];
    HelperResponse *resp = [d handle:req];
    XCTAssertFalse(resp.ok);
    XCTAssertEqualObjects(resp.errorCode, @"invalid_request");
    XCTAssertNil(f.lastAddresses);
}

- (void)testProtocolMismatch {
    HelperDispatcher *d = [[HelperDispatcher alloc] initWithFacade:[StubFacade new]];
    HelperRequest *req = [self reqWithId:@"1" cmd:@"ping"]; req.v = 2;
    HelperResponse *resp = [d handle:req];
    XCTAssertFalse(resp.ok);
    XCTAssertEqualObjects(resp.errorCode, @"protocol_mismatch");
}

- (void)testPing {
    HelperDispatcher *d = [[HelperDispatcher alloc] initWithFacade:[StubFacade new]];
    HelperResponse *resp = [d handle:[self reqWithId:@"9" cmd:@"ping"]];
    XCTAssertTrue(resp.ok);
    XCTAssertEqualObjects(resp.reqId, @"9");
}

- (void)testSendTextSuccess {
    StubFacade *f = [StubFacade new]; f.sendSucceeds = YES;
    HelperDispatcher *d = [[HelperDispatcher alloc] initWithFacade:f];
    HelperRequest *req = [self reqWithId:@"1" cmd:@"send-text"];
    req.chatGuid = @"g"; req.body = @"hi";
    HelperResponse *resp = [d handle:req];
    XCTAssertTrue(resp.ok);
    XCTAssertEqualObjects(f.lastBody, @"hi");
}

- (void)testUnknownCommand {
    HelperDispatcher *d = [[HelperDispatcher alloc] initWithFacade:[StubFacade new]];
    HelperResponse *resp = [d handle:[self reqWithId:@"1" cmd:@"frobnicate"]];
    XCTAssertFalse(resp.ok);
    XCTAssertEqualObjects(resp.errorCode, @"unknown_command");
}

@end
