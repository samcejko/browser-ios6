# Surfari - web browser for jailbroken iOS 6.x (armv7) with its own TLS stack.
# Built with Theos. Deployment target iOS 6.0, compiled against the iOS 9.3 SDK.

TARGET := iphone:clang:9.3:6.0
ARCHS := armv7
DEBUG ?= 0

# Device used by `make install` (Theos): THEOS_DEVICE_IP=<address> on the command line or in the environment, else
# "ipad" from tools/local.json (see tools/local.example.json; tools/ipad.ps1 reads the same file). Without either,
# Theos installs on the machine it runs on.
ifeq ($(origin THEOS_DEVICE_IP),undefined)
SURFARI_LOCAL_IPAD := $(shell sed -n 's/.*"ipad"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' tools/local.json 2>/dev/null)
ifneq ($(SURFARI_LOCAL_IPAD),)
THEOS_DEVICE_IP := $(SURFARI_LOCAL_IPAD)
endif
endif
THEOS_DEVICE_USER ?= root

include $(THEOS)/makefiles/common.mk

# (the bundle id stays com.samcejko.browser - see Resources/Info.plist - so updates keep the data of earlier builds)
APPLICATION_NAME := Surfari

# woff2 decoder (C++) and the brotli decoder it needs (C); fetched by CI into vendor/
WOFF2_FILES := vendor/woff2/src/woff2_dec.cc vendor/woff2/src/woff2_common.cc vendor/woff2/src/woff2_out.cc \
               vendor/woff2/src/table_tags.cc vendor/woff2/src/variable_length.cc
BROTLI_FILES := $(wildcard vendor/brotli/c/common/*.c) $(wildcard vendor/brotli/c/dec/*.c)
# libwebp decoder (encoder dsp files are removed by CI)
WEBP_FILES := $(wildcard vendor/libwebp/src/dec/*.c) $(wildcard vendor/libwebp/src/dsp/*.c) $(wildcard vendor/libwebp/src/utils/*.c) $(wildcard vendor/libwebp/src/demux/*.c)

Surfari_FILES := $(wildcard src/*.m) $(wildcard src/*/*.m) $(wildcard src/*/*.mm) \
                 vendor/mbedtls_glue.c vendor/cxx_glue.cc \
                 $(wildcard vendor/mbedtls/library/*.c) \
                 $(WOFF2_FILES) $(BROTLI_FILES) $(WEBP_FILES)

# (AVFoundation and MediaPlayer: the audio session and the lock screen's title for playing in the background)
Surfari_FRAMEWORKS := UIKit Foundation CoreGraphics QuartzCore Security ImageIO AVFoundation MediaPlayer

# Flags for every C-family file (also the vendored mbedTLS sources)
Surfari_CFLAGS := -Isrc -Isrc/Net -Isrc/UI -Isrc/Model \
                  -Ivendor -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
                  -Ivendor/woff2/include -Ivendor/brotli/c/include -Ivendor/libwebp -Ivendor/libwebp/src \
                  -Os -fvisibility=hidden \
                  -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                  -Wno-deprecated-declarations -Wno-unknown-warning-option \
                  -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# C++ (woff2) and Objective-C++ (the font converter wrapper)
Surfari_CCFLAGS := -std=c++11 -stdlib=libc++ -fno-exceptions -fno-rtti -Wno-unused-parameter
Surfari_OBJCCFLAGS := -std=c++11 -stdlib=libc++ -fobjc-arc -fno-exceptions -fno-rtti

# Objective-C only: ARC; APIs newer than iOS 6.0 are warnings here and turned into errors for our own
# sources by the pragma in src/BRCommon.h (vendored code only warns).
Surfari_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

Surfari_LDFLAGS := -lz -lc++ -lc++abi

# Entitlements: dynamic-codesigning switches on the Nitro JIT inside UIWebView on jailbroken devices.
Surfari_CODESIGN_FLAGS := -SResources/entitlements.plist

include $(THEOS)/makefiles/application.mk

# brmem: a command-line tool for the iPad (run over SSH as root) listing every process's resident memory and the
# system's free/active/inactive/wired pages (jetsam kills the browser when the system as a whole runs short). A
# developer tool: it is built, but kept out of the package (after-stage below; KEEP_BRMEM=1 leaves it in /usr/bin).
TOOL_NAME := brmem
brmem_FILES := tools/brmem/brmem.c
brmem_CFLAGS := -Wall -Wno-unused-parameter
brmem_INSTALL_PATH := /usr/bin
include $(THEOS)/makefiles/tool.mk

SURFARI_STAGED_APP := $(THEOS_STAGING_DIR)/Applications/Surfari.app
SURFARI_STAGED_BIN := $(SURFARI_STAGED_APP)/Surfari
SURFARI_DOC_DIR := $(THEOS_STAGING_DIR)/usr/share/doc/com.samcejko.browser

# After staging, for the .deb and for CI's IPAs (made from the staged app):
# - The iOS 9.3 SDK places the NSURL* classes (NSURLCache, NSCachedURLResponse, NSURLProtocol, ...) in CFNetwork, so
#   the linker binds them to an implicit CFNetwork dependency. On iOS 6 those classes live in Foundation and dyld
#   aborts at launch ("Symbol not found ... Expected in CFNetwork"). Pointing the CFNetwork load command at Foundation
#   makes dyld look them up in Foundation (which re-exports CFNetwork on newer systems), then the binary is signed
#   again because the change invalidates the signature.
# - The root copies of the page shims go when the minified js/<name>.js that CI makes from them is there: the app
#   takes js/ first and the root copy only without it (BRCSSRewriter polyfillBundle). cssfix.js and jsfix.js stay at
#   the root: the app's own rewriters load those. entitlements.plist is for the signing only.
# - brmem moves to packages/brmem (CI publishes it as an artifact of its own).
# - LICENSE and the third-party notices go to /usr/share/doc/<package>, as dpkg packages have them, and a postinst
#   rebuilds the home screen's app list: after dpkg -i or Filza the icon would stay missing until uicache runs.
# - A preinst refuses the .deb while an IPA copy of the app is installed: both have one bundle id, LaunchServices
#   registers only one of them, and the other's bookmarks and history would seem gone. (An IPA copy is a Surfari.app,
#   or a Browser.app of the builds before the rename, under /var/mobile/Applications whose Info.plist names the
#   bundle id; the id is plain ASCII in a binary plist as well.)
after-stage::
	install_name_tool -change /System/Library/Frameworks/CFNetwork.framework/CFNetwork /System/Library/Frameworks/Foundation.framework/Foundation "$(SURFARI_STAGED_BIN)"
	ldid -SResources/entitlements.plist "$(SURFARI_STAGED_BIN)"
	for n in shims shims-extra page-prelude regexp-shim; do \
		if [ -s "$(SURFARI_STAGED_APP)/js/$$n.js" ]; then rm -f "$(SURFARI_STAGED_APP)/$$n.js"; fi; \
	done
	rm -f "$(SURFARI_STAGED_APP)/entitlements.plist"
ifneq ($(KEEP_BRMEM),1)
	if [ -f "$(THEOS_STAGING_DIR)/usr/bin/brmem" ]; then \
		mkdir -p "$(THEOS_PROJECT_DIR)/packages" && mv -f "$(THEOS_STAGING_DIR)/usr/bin/brmem" "$(THEOS_PROJECT_DIR)/packages/brmem"; \
		rmdir "$(THEOS_STAGING_DIR)/usr/bin" 2>/dev/null || true; \
	fi
endif
	mkdir -p "$(SURFARI_DOC_DIR)" "$(THEOS_STAGING_DIR)/DEBIAN"
	cp LICENSE THIRD_PARTY_NOTICES.md "$(SURFARI_DOC_DIR)/"
	printf '%s\n' '#!/bin/sh' \
		'[ "$$1" = configure ] || exit 0' \
		'command -v uicache >/dev/null 2>&1 || exit 0' \
		'if [ "$$(id -u 2>/dev/null)" = 0 ]; then su mobile -c uicache >/dev/null 2>&1 || su -c uicache mobile >/dev/null 2>&1; else uicache >/dev/null 2>&1; fi' \
		'exit 0' > "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	printf '%s\n' '#!/bin/sh' \
		'case "$$1" in install|upgrade) ;; *) exit 0 ;; esac' \
		'for d in /var/mobile/Applications/*/Surfari.app /var/mobile/Applications/*/Browser.app; do' \
		'  [ -f "$$d/Info.plist" ] || continue' \
		'  if grep -q com.samcejko.browser "$$d/Info.plist" 2>/dev/null; then' \
		'    echo "Surfari is already installed from an IPA ($$d)." >&2' \
		'    echo "Delete that copy from the home screen first: the IPA and the .deb cannot be installed together." >&2' \
		'    exit 1' \
		'  fi' \
		'done' \
		'exit 0' > "$(THEOS_STAGING_DIR)/DEBIAN/preinst"
	chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/preinst"
