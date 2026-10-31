ifdef PREFIX
BIN_DIR ?= $(PREFIX)/bin
else
BIN_DIR ?= $(HOME)/Developer/tools
endif

build:
	swift build -c release

test:
	swift test

lint:
	swiftlint lint --strict

install: build
	install -d "$(BIN_DIR)"
	install .build/release/simlease "$(BIN_DIR)/simlease"

app:
	./scripts/make-app.sh

.PHONY: app build install lint test
