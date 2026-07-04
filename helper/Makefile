# helper/Makefile
CC = clang
SDK = $(shell xcrun --show-sdk-path)
FRAMEWORKS = -framework Foundation
CFLAGS = -isysroot $(SDK) -fobjc-arc -Wall -Wextra -Iinclude
TESTCFLAGS = -isysroot $(SDK) -fobjc-arc -Wall -Wextra -Iinclude -fmodules
BUILD = build

.PHONY: dylib test clean
dylib: $(BUILD)/imessage-max-helper.dylib

$(BUILD)/imessage-max-helper.dylib: src/*.m include/*.h | $(BUILD)
	$(CC) $(CFLAGS) $(FRAMEWORKS) -dynamiclib -o $@ src/*.m

$(BUILD):
	mkdir -p $(BUILD)

XCTEST = $(shell xcrun -f xctest)
TESTBUNDLE = $(BUILD)/HelperTests.xctest
XCODE_FRAMEWORKS = -F$(shell xcrun --show-sdk-platform-path)/Developer/Library/Frameworks

test: $(TESTBUNDLE)
	xcrun xctest $(TESTBUNDLE)

$(TESTBUNDLE): src/*.m test/*.m include/*.h | $(BUILD)
	mkdir -p $(TESTBUNDLE)/Contents/MacOS
	$(CC) $(TESTCFLAGS) $(XCODE_FRAMEWORKS) $(FRAMEWORKS) -framework XCTest \
		-bundle -o $(TESTBUNDLE)/Contents/MacOS/HelperTests \
		$(filter-out src/HelperEntry.m,$(wildcard src/*.m)) test/*.m

clean:
	rm -rf $(BUILD)
