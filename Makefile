# Stolnk for macOS.
#
#   make build      compile the package
#   make test       unit tests, including the cross-language crypto vectors
#   make app        assemble and sign build/Stolnk.app
#   make run        build the app bundle and launch it
#   make dmg        universal, signed, packaged — no notarisation, so the
#                   result opens here and nowhere else. For checking packaging.
#   make release    the full chain: universal, Developer ID, notarised,
#                   stapled, verified. Needs the certificate and a stored
#                   notarytool profile — see Scripts/release.sh.
#   make identity   only for a Mac with no Apple Development certificate:
#                   creates a self-signed one, so the keychain stops
#                   re-prompting for the device key after every build

CONFIGURATION ?= release

.PHONY: build build-universal test app run dmg release identity clean

build:
	swift build -c $(CONFIGURATION)

build-universal:
	swift build -c $(CONFIGURATION) --arch arm64 --arch x86_64

test:
	swift test

app: build
	CONFIGURATION=$(CONFIGURATION) ./Scripts/bundle.sh

run: app
	open build/Stolnk.app

dmg:
	SKIP_NOTARIZE=1 ./Scripts/release.sh

release:
	./Scripts/release.sh

identity:
	./Scripts/dev-identity.sh

clean:
	swift package clean
	rm -rf build
