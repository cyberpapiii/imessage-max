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
