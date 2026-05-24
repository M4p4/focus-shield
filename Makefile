.PHONY: proxy app run run-app clean tidy test

BUILD_DIR := build
PROXY_BIN := $(BUILD_DIR)/bhb-proxy
APP_NAME  := BadHabitBlocker
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
APP_BIN := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_RES := $(APP_BUNDLE)/Contents/Resources

SWIFT_SOURCES := $(wildcard app/*.swift)
SDK := $(shell xcrun --sdk macosx --show-sdk-path)

proxy:
	mkdir -p $(BUILD_DIR)
	cd proxy && go build -trimpath -o ../$(PROXY_BIN) .

run: proxy
	./$(PROXY_BIN) -v

# Build the Swift menubar app. Bundles the proxy binary into Resources so
# ProxyController can find it at runtime.
app: proxy
	@echo "→ building $(APP_BUNDLE)"
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_RES)
	cp app/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(PROXY_BIN) $(APP_RES)/bhb-proxy
	swiftc \
	  -sdk $(SDK) \
	  -target arm64-apple-macosx13.0 \
	  -O \
	  -parse-as-library \
	  -module-name $(APP_NAME) \
	  -o $(APP_BIN) \
	  $(SWIFT_SOURCES)
	@echo "→ built $(APP_BUNDLE)"

run-app: app
	open $(APP_BUNDLE)

test:
	cd proxy && go test ./...

tidy:
	cd proxy && go mod tidy

clean:
	rm -rf $(BUILD_DIR)
