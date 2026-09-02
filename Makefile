# Stolnk for macOS.
#
#   make build      compile the package
#   make test       unit tests, including the cross-language crypto vectors
#   make app        assemble and sign build/Stolnk.app
#   make run        build the app bundle and launch it
#   make identity   only for a Mac with no Apple Development certificate:
#                   creates a self-signed one, so the keychain stops
#                   re-prompting for the device key after every build

CONFIGURATION ?= release

.PHONY: build test app run identity clean format

build:
	swift build -c $(CONFIGURATION)

test:
	swift test

app: build
	CONFIGURATION=$(CONFIGURATION) ./Scripts/bundle.sh

run: app
	open build/Stolnk.app

identity:
	./Scripts/dev-identity.sh

clean:
	swift package clean
	rm -rf build
