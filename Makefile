PREFIX ?= /usr/local
BUILD_DIR := .build/release
BIN := $(BUILD_DIR)/tmux-ai-pet

.PHONY: build test run app install-agent uninstall-agent install-hooks uninstall-hooks clean

build:
	SWIFTPM_DISABLE_SANDBOX=1 swift build -c release --disable-sandbox

test:
	SWIFTPM_DISABLE_SANDBOX=1 swift test --disable-sandbox

run:
	swift run tmux-ai-pet

app:
	./Scripts/build_app.sh

install-agent:
	./Scripts/install-launch-agent.sh

uninstall-agent:
	./Scripts/uninstall-launch-agent.sh

install-hooks:
	./Scripts/install-tmux-hooks.sh

uninstall-hooks:
	./Scripts/uninstall-tmux-hooks.sh

clean:
	swift package clean
