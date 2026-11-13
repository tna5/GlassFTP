CONFIG ?= release

.PHONY: build bundle run debug test clean icon banner dist

build:
	swift build -c $(CONFIG)

bundle: build
	CONFIG=$(CONFIG) ./scripts/bundle.sh

run: bundle
	@pkill -x GlassFTP 2>/dev/null || true
	open build/GlassFTP.app

debug:
	$(MAKE) run CONFIG=debug

# Command Line Tools ship no XCTest, so the assertions live in the binary
# behind a launch argument.
#
# Built release on purpose: the suite includes a 50,000-entry benchmark, and a
# debug build runs it roughly eight times slower, which would make the timings
# meaningless as a regression guard.
test:
	swift build -c release
	./.build/release/GlassFTP --self-test

icon:
	./scripts/make-icon.sh

banner:
	@test -f Resources/IconVariants/icon-1c-bold.png || ./scripts/make-icon.sh
	swift scripts/BannerRenderer.swift Resources/IconVariants/icon-1c-bold.png build/banners
	cp build/banners/banner-3-window.png docs/banner.png

# Release build, zipped for a GitHub release: dist/GlassFTP-<version>.zip
dist:
	$(MAKE) bundle CONFIG=release
	@mkdir -p dist
	@VERSION=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist); \
	ditto -c -k --keepParent build/GlassFTP.app dist/GlassFTP-$$VERSION.zip && \
	shasum -a 256 dist/GlassFTP-$$VERSION.zip

clean:
	rm -rf .build build dist
