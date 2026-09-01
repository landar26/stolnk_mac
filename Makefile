# Stolnk for macOS.
#
#   make build   compile the package
#   make test    unit tests, including the cross-language crypto vectors
#   make app     assemble and sign build/Stolnk.app
#   make run     build the app bundle and launch it

CONFIGURATION ?= release

.PHONY: build test app run clean format

build:
	swift build -c $(CONFIGURATION)

test:
	swift test

app: build
	CONFIGURATION=$(CONFIGURATION) ./Scripts/bundle.sh

run: app
	open build/Stolnk.app

clean:
	swift package clean
	rm -rf build
