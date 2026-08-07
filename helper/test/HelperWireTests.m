#import <XCTest/XCTest.h>
#import "HelperWire.h"

@interface HelperWireTests : XCTestCase
@end

@implementation HelperWireTests

- (void)testDecodeCreateChatRequest {
    NSData *line = [@"{\"v\":1,\"id\":\"a\",\"cmd\":\"create-chat\",\"addresses\":[\"+1\",\"+2\"],\"service\":\"iMessage\"}"
                    dataUsingEncoding:NSUTF8StringEncoding];
    NSString *errId = nil;
    HelperRequest *req = [HelperWire decodeRequestLine:line error:&errId];
    XCTAssertNotNil(req);
    XCTAssertEqual(req.v, 1);
    XCTAssertEqualObjects(req.reqId, @"a");
    XCTAssertEqualObjects(req.cmd, @"create-chat");
    XCTAssertEqualObjects(req.addresses, (@[@"+1", @"+2"]));
    XCTAssertEqualObjects(req.service, @"iMessage");
}

- (void)testEncodeOkResponseHasSnakeCaseGuidAndTrailingNewline {
    HelperResponse *resp = [HelperResponse okWithId:@"a" chatGuid:@"iMessage;+;g"];
    NSData *data = [HelperWire encodeResponse:resp];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    XCTAssertTrue([text hasSuffix:@"\n"]);
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(obj[@"v"], @1);
    XCTAssertEqualObjects(obj[@"id"], @"a");
    XCTAssertEqualObjects(obj[@"ok"], @YES);
    XCTAssertEqualObjects(obj[@"chat_guid"], @"iMessage;+;g");
    XCTAssertNil(obj[@"error"]);
}

- (void)testEncodeErrorResponseNestsCodeAndMessage {
    HelperResponse *resp = [HelperResponse errorWithId:@"x" code:@"handle_not_found" message:@"no"];
    NSData *data = [HelperWire encodeResponse:resp];
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(obj[@"ok"], @NO);
    XCTAssertEqualObjects(obj[@"error"][@"code"], @"handle_not_found");
    XCTAssertEqualObjects(obj[@"error"][@"message"], @"no");
    XCTAssertNil(obj[@"chat_guid"]);
}

- (void)testDecodeMalformedReturnsNilWithEmptyId {
    NSData *line = [@"{not json" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *errId = nil;
    HelperRequest *req = [HelperWire decodeRequestLine:line error:&errId];
    XCTAssertNil(req);
    XCTAssertEqualObjects(errId, @"");
}

@end
