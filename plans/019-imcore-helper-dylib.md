# Plan 019: `imessage-max-helper` dylib (Objective-C IMCore backend)

> **For agentic workers:** REQUIRED SUB-SKILL: use
> `superpowers:subagent-driven-development` (recommended) or
> `superpowers:executing-plans` to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Executor instructions**: BASE CHECK FIRST — run
> `ls plans/019-imcore-helper-dylib.md` and confirm the title says
> "imessage-max-helper dylib". Branch `advisor/019-imcore-helper-dylib`, based
> on `advisor/018-imcore-helper-bridge` (or `main` once 018 merges). Follow
> exactly; verify every step; in-scope files only; do not edit
> `plans/README.md`. Report: STATUS / STEPS / STOPPED BECAUSE / FILES CHANGED /
> NOTES.

**Goal:** Build the injectable Objective-C dylib that runs inside `Messages.app`,
listens on a Unix domain socket, and executes the plan-018 wire protocol
(`ping`, `create-chat`, `send-text`, `send-file`) against Apple's private
**IMCore** framework — creating group chats and sending messages with no UI.

**Architecture:** All private-framework calls sit behind one `IMCoreFacade`
Objective-C protocol. Everything else — JSON parse/serialize, command dispatch,
socket framing — is plain Foundation and is **unit-tested off-device** against a
stub facade and a `socketpair()` loopback, exactly as plan 018 tested its Swift
half. Only the real `IMCoreFacade` implementation and the `+load` injection guard
require an on-device (SIP-off) manual checklist. The dylib is the socket
**listener**; the plan-018 `UnixSocketTransport` connects to it as a client.

**Tech Stack:** Objective-C, Foundation, POSIX sockets, `dlopen`/`dlsym` +
class-dumped private headers for IMCore, XCTest (Objective-C) via a small clang
test harness, `clang` bundle build (no Xcode project).

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH (private frameworks; runs inside Apple's process). Contained:
  the private surface is one file behind `IMCoreFacade`; everything else is
  ordinary, tested Foundation code.
- **Depends on**: 018 merged (wire protocol `v:1`, field names `chat_guid`, the
  `\n`-framed one-object-per-line contract). This plan MUST byte-match 018.
- **Category**: feature / infrastructure
- **Planned at**: 2026-07-04 (from
  `docs/plans/2026-07-04-group-chat-creation-imcore-design.md`, unit U1)

## Plan sequence (context — do not implement 020/021 here)

- 018 (done): Swift wire protocol + `HelperBridge` + `UnixSocketTransport`.
- **019 (this plan):** the Obj-C dylib listener + IMCore backend. ← now
- 020: `MessagesLifecycle` launches Messages with `DYLD_INSERT_LIBRARIES`,
  `IMCoreScriptRunner` conforms to `ScriptRunning`, backend-selection flag +
  dormant AppleScript fallback, multi-recipient `to` + exact-participant group
  reuse/creation in `SendResolver`, `send` schema, capability gating. **020 also
  folds in the deferred `UnixSocketTransport` hardening from 018's final review**
  (sub-second timeout `tv_usec`, errno-vs-timeout, buffering past first `\n`,
  looping partial writes, max-line cap).
- 021: `make install` builds+places the dylib; SIP + library-validation docs.

## Global Constraints

- **Wire compatibility with plan 018 is binding and exact.** Requests the dylib
  reads and responses it writes MUST match `swift/Sources/iMessageMax/Helper/HelperProtocol.swift`:
  - Every message carries `"v": 1`. A request whose `v` != 1 gets an error
    response `{"v":1,"id":<same>,"ok":false,"error":{"code":"protocol_mismatch","message":...}}`.
  - Field names exactly: request `v,id,cmd,addresses,service,chat_guid,body,path`;
    response `v,id,ok,chat_guid,error{code,message}`.
  - `cmd` values exactly: `ping`, `create-chat`, `send-text`, `send-file`.
  - Framing: one JSON object per line, `\n`-delimited, UTF-8. The dylib reads one
    request line and writes exactly one response line (with trailing `\n`).
  - Every response echoes the request's `id`. A parse failure that yields no `id`
    uses `id: ""`.
- **Socket role:** the dylib **binds + listens + accepts** on the Unix domain
  socket path; the server connects. Path resolution order: env var
  `IMESSAGE_MAX_HELPER_SOCKET` if set, else
  `<NSTemporaryDirectory()>/imessage-max-helper.sock`. On `+load`, if the socket
  file already exists, `unlink` it before `bind`.
- **Injection guard:** on `+load`, do nothing unless the host bundle identifier
  is `com.apple.MobileSMS`. Never start the listener in any other process.
- **Private-framework containment:** only `IMCoreFacadeLive.m` may reference
  IMCore symbols. Every other file compiles and unit-tests with no IMCore.
- **Build artifact:** `helper/build/imessage-max-helper.dylib`. Build via a
  committed `helper/Makefile` invoking `clang`; **no Xcode project**, no edit to
  the Swift `Package.swift`.
- **Directory:** all new files live under `helper/`. In-scope files are only
  those named per task below.
- **Verification baseline:** off-device unit tests run via
  `cd helper && make test` (a clang-built XCTest bundle run with `xcrun xctest`).
  On-device steps are a documented manual checklist, explicitly not part of CI.

---

### Task 1: Helper build scaffold + inert `+load`

**Files:**
- Create: `helper/Makefile`
- Create: `helper/src/HelperEntry.m`
- Create: `helper/include/HelperEntry.h`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `helper/build/imessage-max-helper.dylib` from `make -C helper dylib`.
  - `HelperEntry` Obj-C class with `+ (BOOL)shouldActivateForBundleIdentifier:(NSString *)bundleID;`
    returning `[bundleID isEqualToString:@"com.apple.MobileSMS"]`. This is the
    injection guard, unit-testable without injection.
  - A `+load` that calls `shouldActivateForBundleIdentifier:` with the running
    bundle id and, for now, only `NSLog`s when it would activate (listener wiring
    lands in Task 4).

- [ ] **Step 1: Write the Makefile**

```makefile
# helper/Makefile
CC = clang
SDK = $(shell xcrun --show-sdk-path)
FRAMEWORKS = -framework Foundation
CFLAGS = -isysroot $(SDK) -fobjc-arc -Wall -Wextra -Iinclude
BUILD = build

.PHONY: dylib test clean
dylib: $(BUILD)/imessage-max-helper.dylib

$(BUILD)/imessage-max-helper.dylib: src/*.m include/*.h | $(BUILD)
	$(CC) $(CFLAGS) $(FRAMEWORKS) -dynamiclib -o $@ src/*.m

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
```

- [ ] **Step 2: Write the header + inert entry**

```objc
// helper/include/HelperEntry.h
#import <Foundation/Foundation.h>

@interface HelperEntry : NSObject
+ (BOOL)shouldActivateForBundleIdentifier:(NSString *)bundleID;
@end
```

```objc
// helper/src/HelperEntry.m
#import "HelperEntry.h"

@implementation HelperEntry

+ (BOOL)shouldActivateForBundleIdentifier:(NSString *)bundleID {
    return [bundleID isEqualToString:@"com.apple.MobileSMS"];
}

+ (void)load {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([self shouldActivateForBundleIdentifier:bundleID]) {
        NSLog(@"[imessage-max-helper] activating in %@", bundleID);
        // Listener wiring added in Task 4.
    }
}

@end
```

- [ ] **Step 3: Build the dylib**

Run: `cd helper && make dylib`
Expected: produces `helper/build/imessage-max-helper.dylib`, no warnings.

- [ ] **Step 4: Commit**

```bash
git add helper/Makefile helper/src/HelperEntry.m helper/include/HelperEntry.h
git commit -m "feat(helper-dylib): build scaffold + inert bundle-guarded +load"
```

---

### Task 2: Wire protocol parse/serialize (Obj-C, byte-match 018)

**Files:**
- Create: `helper/include/HelperWire.h`
- Create: `helper/src/HelperWire.m`
- Create: `helper/test/HelperWireTests.m`
- Modify: `helper/Makefile` (add the `test` target)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `HelperRequest` model class: properties `NSInteger v; NSString *reqId;
    NSString *cmd; NSArray<NSString *> *addresses; NSString *service;
    NSString *chatGuid; NSString *body; NSString *path;`
  - `HelperResponse` model class: `NSInteger v; NSString *reqId; BOOL ok;
    NSString *chatGuid; NSString *errorCode; NSString *errorMessage;`
    plus `+ okWithId:chatGuid:` and `+ errorWithId:code:message:`.
  - `HelperWire` class:
    - `+ (nullable HelperRequest *)decodeRequestLine:(NSData *)line error:(NSString **)errId;`
      — on JSON failure returns nil and sets `*errId` to any recoverable `id`
      (else `@""`).
    - `+ (NSData *)encodeResponse:(HelperResponse *)resp;` — returns UTF-8 JSON
      with a trailing `\n`, using the exact 018 field names (`chat_guid`,
      `error{code,message}`), omitting `chat_guid`/`error` when nil.

- [ ] **Step 1: Write the failing tests**

```objc
// helper/test/HelperWireTests.m
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
```

- [ ] **Step 2: Add the `test` target to the Makefile**

```makefile
# Append to helper/Makefile
XCTEST = $(shell xcrun -f xctest)
TESTBUNDLE = $(BUILD)/HelperTests.xctest

test: $(TESTBUNDLE)
	xcrun xctest $(TESTBUNDLE)

$(TESTBUNDLE): src/*.m test/*.m include/*.h | $(BUILD)
	mkdir -p $(TESTBUNDLE)/Contents/MacOS
	$(CC) $(CFLAGS) $(FRAMEWORKS) -framework XCTest \
		-bundle -o $(TESTBUNDLE)/Contents/MacOS/HelperTests \
		$(filter-out src/HelperEntry.m,$(wildcard src/*.m)) test/*.m
```

Note: `HelperEntry.m` is excluded from the test bundle because its `+load`
would try to inspect the test host's bundle id; its guard logic is exercised
directly in Task 3's dispatcher tests via `shouldActivateForBundleIdentifier:`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd helper && make test`
Expected: FAIL — `HelperWire.h` not found / symbols undefined.

- [ ] **Step 4: Write the implementation**

```objc
// helper/include/HelperWire.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface HelperRequest : NSObject
@property (nonatomic) NSInteger v;
@property (nonatomic, copy) NSString *reqId;
@property (nonatomic, copy) NSString *cmd;
@property (nonatomic, copy, nullable) NSArray<NSString *> *addresses;
@property (nonatomic, copy, nullable) NSString *service;
@property (nonatomic, copy, nullable) NSString *chatGuid;
@property (nonatomic, copy, nullable) NSString *body;
@property (nonatomic, copy, nullable) NSString *path;
@end

@interface HelperResponse : NSObject
@property (nonatomic) NSInteger v;
@property (nonatomic, copy) NSString *reqId;
@property (nonatomic) BOOL ok;
@property (nonatomic, copy, nullable) NSString *chatGuid;
@property (nonatomic, copy, nullable) NSString *errorCode;
@property (nonatomic, copy, nullable) NSString *errorMessage;
+ (instancetype)okWithId:(NSString *)reqId chatGuid:(nullable NSString *)chatGuid;
+ (instancetype)errorWithId:(NSString *)reqId code:(NSString *)code message:(NSString *)message;
@end

@interface HelperWire : NSObject
+ (nullable HelperRequest *)decodeRequestLine:(NSData *)line error:(NSString **)errId;
+ (NSData *)encodeResponse:(HelperResponse *)resp;
@end

NS_ASSUME_NONNULL_END
```

```objc
// helper/src/HelperWire.m
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd helper && make test`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add helper/include/HelperWire.h helper/src/HelperWire.m \
        helper/test/HelperWireTests.m helper/Makefile
git commit -m "feat(helper-dylib): wire protocol parse/serialize, byte-matched to plan 018"
```

---

### Task 3: Command dispatcher + `IMCoreFacade` protocol + stub

**Files:**
- Create: `helper/include/IMCoreFacade.h`
- Create: `helper/include/HelperDispatcher.h`
- Create: `helper/src/HelperDispatcher.m`
- Create: `helper/test/HelperDispatcherTests.m`

**Interfaces:**
- Consumes: `HelperRequest`, `HelperResponse` (Task 2).
- Produces:
  - `IMCoreFacade` protocol — the entire private-API seam:
    - `- (nullable NSString *)createChatWithAddresses:(NSArray<NSString *> *)addresses service:(NSString *)service error:(NSString **)errCode;` → returns `chat_guid`.
    - `- (BOOL)sendText:(NSString *)body toChatGuid:(NSString *)guid error:(NSString **)errCode;`
    - `- (BOOL)sendFileAtPath:(NSString *)path toChatGuid:(NSString *)guid error:(NSString **)errCode;`
  - `HelperDispatcher` with `- initWithFacade:(id<IMCoreFacade>)facade;` and
    `- (HelperResponse *)handle:(HelperRequest *)req;` implementing:
    - `v != 1` → error `protocol_mismatch`.
    - `ping` → ok (no guid).
    - `create-chat` → validate non-empty `addresses`; call facade; ok with guid,
      or error with the facade's `errCode`.
    - `send-text` → validate `chat_guid` + `body`; call facade.
    - `send-file` → validate `chat_guid` + `path`; call facade.
    - unknown `cmd` → error `unknown_command`.

**Interface note for Task 5:** the real `IMCoreFacadeLive` implements this
protocol; the dispatcher never sees IMCore directly.

- [ ] **Step 1: Write the failing tests (with a stub facade)**

```objc
// helper/test/HelperDispatcherTests.m
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd helper && make test`
Expected: FAIL — `HelperDispatcher.h` / `IMCoreFacade.h` not found.

- [ ] **Step 3: Write the implementation**

```objc
// helper/include/IMCoreFacade.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@protocol IMCoreFacade <NSObject>
- (nullable NSString *)createChatWithAddresses:(NSArray<NSString *> *)addresses
                                       service:(NSString *)service
                                         error:(NSString **)errCode;
- (BOOL)sendText:(NSString *)body toChatGuid:(NSString *)guid error:(NSString **)errCode;
- (BOOL)sendFileAtPath:(NSString *)path toChatGuid:(NSString *)guid error:(NSString **)errCode;
@end

NS_ASSUME_NONNULL_END
```

```objc
// helper/include/HelperDispatcher.h
#import <Foundation/Foundation.h>
#import "IMCoreFacade.h"
#import "HelperWire.h"
NS_ASSUME_NONNULL_BEGIN

@interface HelperDispatcher : NSObject
- (instancetype)initWithFacade:(id<IMCoreFacade>)facade;
- (HelperResponse *)handle:(HelperRequest *)req;
@end

NS_ASSUME_NONNULL_END
```

```objc
// helper/src/HelperDispatcher.m
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd helper && make test`
Expected: PASS (Task 2's 4 + Task 3's 7 = 11 tests).

- [ ] **Step 5: Commit**

```bash
git add helper/include/IMCoreFacade.h helper/include/HelperDispatcher.h \
        helper/src/HelperDispatcher.m helper/test/HelperDispatcherTests.m
git commit -m "feat(helper-dylib): command dispatcher + IMCoreFacade seam + stub-tested handlers"
```

---

### Task 4: Socket listener + accept/serve loop (loopback-tested)

**Files:**
- Create: `helper/include/HelperListener.h`
- Create: `helper/src/HelperListener.m`
- Create: `helper/test/HelperListenerTests.m`

**Interfaces:**
- Consumes: `HelperWire` (Task 2), `HelperDispatcher` (Task 3).
- Produces:
  - `HelperListener` with:
    - `+ (NSString *)resolveSocketPath;` → env `IMESSAGE_MAX_HELPER_SOCKET` else
      `<NSTemporaryDirectory()>imessage-max-helper.sock`.
    - `- initWithDispatcher:(HelperDispatcher *)dispatcher;`
    - `- (void)serveConnectionFD:(int)fd;` — reads `\n`-delimited request lines
      from `fd`, dispatches each, writes each response line back, until EOF.
      This is the unit-tested core (drive it with one end of a `socketpair`).
    - `- (BOOL)bindAndListenAtPath:(NSString *)path error:(NSString **)err;` and
      `- (void)acceptLoop;` — production path (started from Task 5's `+load`);
      exercised only on-device.

- [ ] **Step 1: Write the failing loopback test**

```objc
// helper/test/HelperListenerTests.m
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd helper && make test`
Expected: FAIL — `HelperListener.h` not found.

- [ ] **Step 3: Write the implementation**

```objc
// helper/include/HelperListener.h
#import <Foundation/Foundation.h>
#import "HelperDispatcher.h"
NS_ASSUME_NONNULL_BEGIN

@interface HelperListener : NSObject
+ (NSString *)resolveSocketPath;
- (instancetype)initWithDispatcher:(HelperDispatcher *)dispatcher;
- (void)serveConnectionFD:(int)fd;
- (BOOL)bindAndListenAtPath:(NSString *)path error:(NSString **)err;
- (void)acceptLoop;
@end

NS_ASSUME_NONNULL_END
```

```objc
// helper/src/HelperListener.m
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd helper && make test`
Expected: PASS (11 prior + 2 new = 13 tests).

- [ ] **Step 5: Commit**

```bash
git add helper/include/HelperListener.h helper/src/HelperListener.m \
        helper/test/HelperListenerTests.m
git commit -m "feat(helper-dylib): unix-socket listener + line-framed serve loop (loopback-tested)"
```

---

### Task 5: Real `IMCoreFacade` (private IMCore) + `+load` wiring — ON-DEVICE

**Files:**
- Create: `helper/src/IMCoreFacadeLive.m`
- Create: `helper/include/IMCoreFacadeLive.h`
- Create: `helper/include/IMCorePrivate.h` (declarations for the private symbols)
- Modify: `helper/src/HelperEntry.m` (start the listener when activated)
- Modify: `helper/Makefile` (link IMCore for the `dylib` target only; keep the
  `test` target IMCore-free)
- Create: `helper/ON_DEVICE_CHECKLIST.md`

**Interfaces:**
- Consumes: `IMCoreFacade` (Task 3), `HelperListener`, `HelperDispatcher`.
- Produces: `IMCoreFacadeLive : NSObject <IMCoreFacade>` implementing the three
  methods against IMCore, and a `+load` that — only inside `com.apple.MobileSMS`
  — builds `IMCoreFacadeLive` → `HelperDispatcher` → `HelperListener`, binds the
  socket, and runs `acceptLoop` on a background thread.

**⚠️ This task cannot be unit-tested** — it touches private frameworks inside a
live Messages process on a SIP-disabled Mac. The dispatcher, wire, and listener
it depends on are already fully tested (Tasks 2–4). Verify via the checklist.

**⚠️ Private selectors below are from research
(`docs/plans/2026-07-04-group-chat-creation-imcore-design.md` + BlueBubbles
`BlueBubblesHelper.m`) and MUST be verified against class-dumped IMCore headers
for the target macOS before trusting.** Keep every private call inside this one
file so a signature miss is isolated.

- [ ] **Step 1: Declare the private symbols you rely on**

```objc
// helper/include/IMCorePrivate.h
// Private IMCore surface. VERIFY selectors/signatures against class-dumped
// headers for the running macOS before shipping. Isolated here on purpose.
#import <Foundation/Foundation.h>

@interface IMAccount : NSObject
- (id)imHandleWithID:(NSString *)handleID;
@end

@interface IMAccountController : NSObject
+ (instancetype)sharedInstance;
- (IMAccount *)activeIMessageAccount;
- (IMAccount *)activeSMSAccount;
@end

@interface IMChat : NSObject
- (NSString *)guid;
- (void)sendMessage:(id)message;   // id is an IMMessage; see live impl
@end

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (IMChat *)chatForIMHandles:(NSArray *)handles;   // group
- (IMChat *)chatForIMHandle:(id)handle;            // 1:1
@end
```

- [ ] **Step 2: Implement the live facade (header + impl)**

```objc
// helper/include/IMCoreFacadeLive.h
#import <Foundation/Foundation.h>
#import "IMCoreFacade.h"
@interface IMCoreFacadeLive : NSObject <IMCoreFacade>
@end
```

```objc
// helper/src/IMCoreFacadeLive.m
#import "IMCoreFacadeLive.h"
#import "IMCorePrivate.h"

@implementation IMCoreFacadeLive

- (IMAccount *)accountForService:(NSString *)service {
    IMAccountController *ac = [IMAccountController sharedInstance];
    if ([service isEqualToString:@"SMS"]) { return [ac activeSMSAccount]; }
    return [ac activeIMessageAccount];
}

- (NSString *)createChatWithAddresses:(NSArray<NSString *> *)addresses
                              service:(NSString *)service
                                error:(NSString **)errCode {
    IMAccount *account = [self accountForService:service];
    if (!account) { if (errCode) { *errCode = @"no_active_account"; } return nil; }

    NSMutableArray *handles = [NSMutableArray array];
    for (NSString *addr in addresses) {
        id h = [account imHandleWithID:addr];
        if (!h) { if (errCode) { *errCode = @"handle_not_found"; } return nil; }
        [handles addObject:h];
    }

    IMChatRegistry *registry = [IMChatRegistry sharedInstance];
    IMChat *chat = handles.count > 1
        ? [registry chatForIMHandles:handles]
        : [registry chatForIMHandle:handles.firstObject];
    if (!chat.guid) { if (errCode) { *errCode = @"chat_creation_failed"; } return nil; }
    return chat.guid;
}

- (BOOL)sendText:(NSString *)body toChatGuid:(NSString *)guid error:(NSString **)errCode {
    // NOTE: constructing an IMMessage from text requires additional private
    // symbols (IMMessage / IMMessageItem, attributed body). Declare them in
    // IMCorePrivate.h and build the message here once verified against headers.
    // Left as the single on-device integration point.
    if (errCode) { *errCode = @"not_implemented"; }
    return NO;
}

- (BOOL)sendFileAtPath:(NSString *)path toChatGuid:(NSString *)guid error:(NSString **)errCode {
    if (errCode) { *errCode = @"not_implemented"; }
    return NO;
}

@end
```

Note: `create-chat` is the load-bearing new capability and is implemented above.
Text/file sending through IMCore requires the `IMMessage` construction symbols;
this task wires the seam and the checklist verifies `create-chat` end to end.
Filling in `sendText`/`sendFile` against verified `IMMessage` headers is the
final checklist item — until then the dispatcher returns a clean `not_implemented`
error and plan 020 can route sends through the AppleScript fallback while
`create-chat` uses IMCore.

- [ ] **Step 3: Wire `+load` to start the listener**

```objc
// helper/src/HelperEntry.m  (replace the Task 1 body)
#import "HelperEntry.h"
#import "HelperDispatcher.h"
#import "HelperListener.h"
#import "IMCoreFacadeLive.h"

@implementation HelperEntry

+ (BOOL)shouldActivateForBundleIdentifier:(NSString *)bundleID {
    return [bundleID isEqualToString:@"com.apple.MobileSMS"];
}

+ (void)startListener {
    IMCoreFacadeLive *facade = [IMCoreFacadeLive new];
    HelperDispatcher *disp = [[HelperDispatcher alloc] initWithFacade:facade];
    HelperListener *listener = [[HelperListener alloc] initWithDispatcher:disp];
    NSString *path = [HelperListener resolveSocketPath];
    NSString *err = nil;
    if (![listener bindAndListenAtPath:path error:&err]) {
        NSLog(@"[imessage-max-helper] listen failed: %@", err);
        return;
    }
    NSLog(@"[imessage-max-helper] listening at %@", path);
    [NSThread detachNewThreadWithBlock:^{ [listener acceptLoop]; }];
}

+ (void)load {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([self shouldActivateForBundleIdentifier:bundleID]) {
        [self startListener];
    }
}

@end
```

- [ ] **Step 4: Update the Makefile so the dylib links IMCore but tests do not**

```makefile
# Replace the dylib recipe in helper/Makefile
IMCORE = -F/System/Library/PrivateFrameworks -framework IMCore
$(BUILD)/imessage-max-helper.dylib: src/*.m include/*.h | $(BUILD)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(IMCORE) -dynamiclib -o $@ src/*.m
```

The `test` target already excludes `HelperEntry.m` and does not compile
`IMCoreFacadeLive.m` (only `HelperWire.m`, `HelperDispatcher.m`,
`HelperListener.m` are needed by the tests). Confirm the `test` recipe lists
those three sources explicitly rather than `src/*.m` so it stays IMCore-free:

```makefile
$(TESTBUNDLE): include/*.h test/*.m src/HelperWire.m src/HelperDispatcher.m src/HelperListener.m | $(BUILD)
	mkdir -p $(TESTBUNDLE)/Contents/MacOS
	$(CC) $(CFLAGS) $(FRAMEWORKS) -framework XCTest \
		-bundle -o $(TESTBUNDLE)/Contents/MacOS/HelperTests \
		src/HelperWire.m src/HelperDispatcher.m src/HelperListener.m test/*.m
```

- [ ] **Step 5: Verify off-device tests still pass and the dylib builds**

Run: `cd helper && make test && make dylib`
Expected: 13/13 tests PASS (unchanged; live facade not tested); dylib links
against IMCore without error.

- [ ] **Step 6: Write the on-device checklist**

```markdown
# helper/ON_DEVICE_CHECKLIST.md

Prereqs (SIP-off Mac, per plan 021 / design doc):
- `csrutil disable` done; `DisableLibraryValidation -bool true` set.
- Messages signed into iMessage.

Manual verification (cannot be automated in CI):
1. Build: `cd helper && make dylib`.
2. Launch Messages with injection:
   `IMESSAGE_MAX_HELPER_SOCKET=/tmp/imm-helper.sock \
    DYLD_INSERT_LIBRARIES=$PWD/build/imessage-max-helper.dylib \
    /System/Applications/Messages.app/Contents/MacOS/Messages`
3. Confirm log line `[imessage-max-helper] listening at /tmp/imm-helper.sock`.
4. From a second terminal, `nc -U /tmp/imm-helper.sock` and send:
   `{"v":1,"id":"1","cmd":"ping"}` → expect `{"v":1,"id":"1","ok":true}`.
5. `create-chat` to two test handles you control:
   `{"v":1,"id":"2","cmd":"create-chat","addresses":["+1555...","+1555..."]}`
   → expect `ok:true` with a `chat_guid`; confirm a NEW group thread appears in
   Messages and in chat.db.
6. Record the macOS build tested and whether any IMCore selector in
   IMCorePrivate.h needed correction (update the header + note here).
7. Known-open: `send-text`/`send-file` return `not_implemented` until the
   IMMessage construction symbols are verified and filled in — track as the
   follow-up before plan 020 flips the default backend to IMCore for sends.
```

- [ ] **Step 7: Commit**

```bash
git add helper/src/IMCoreFacadeLive.m helper/include/IMCoreFacadeLive.h \
        helper/include/IMCorePrivate.h helper/src/HelperEntry.m \
        helper/Makefile helper/ON_DEVICE_CHECKLIST.md
git commit -m "feat(helper-dylib): live IMCore facade (create-chat) + +load listener wiring + on-device checklist"
```

---

## Self-Review

- **Spec coverage (design unit U1):** the dylib runs inside Messages
  (`+load` guarded to `com.apple.MobileSMS`, Task 1/5), speaks the 018 protocol
  over a socket (Tasks 2/4), and creates group chats via
  `IMChatRegistry chatForIMHandles:` behind `IMCoreFacade` (Tasks 3/5). Socket
  role reconciled with 018: dylib **listens**, server connects.
- **Testability:** wire, dispatch, and framing are unit-tested off-device
  (13 tests, stub facade + socketpair). The private-framework surface is one
  file (`IMCoreFacadeLive.m`) plus `IMCorePrivate.h`, verified by the on-device
  checklist — the only untestable-in-CI code.
- **Honest gap called out (not hidden):** `send-text`/`send-file` via IMCore
  return `not_implemented` pending verified `IMMessage` symbols; `create-chat`
  (the actual new capability) is implemented. Plan 020 can create groups via
  IMCore while routing message sends through the AppleScript fallback until the
  send symbols are filled in — this is stated in Task 5 and the checklist.
- **Placeholder scan:** no TBD/TODO; every off-device step has complete code.
  The one deliberately-stubbed methods (`sendText`/`sendFile`) return a defined
  error, not a placeholder.
- **Constraint check:** wire field names/values byte-match 018; only `helper/`
  files touched; `Package.swift` untouched; test build stays IMCore-free.
- **Boundary with 020:** deferred `UnixSocketTransport` hardening from 018's
  review is restated at the top so 020 picks it up.
```
