PREFIX ?= /usr/local

build:
	swift build -c release

test:
	swift test

lint:
	swiftlint lint --strict

install: build
	install -d $(PREFIX)/bin
	install .build/release/simlease $(PREFIX)/bin/simlease

app:
	./scripts/make-app.sh

.PHONY: app build install lint test
