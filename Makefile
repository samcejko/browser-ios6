# Browser - web browser for jailbroken iOS 6.x (armv7) with its own TLS stack.
# Built with Theos. Deployment target iOS 6.0, compiled against the iOS 9.3 SDK.

TARGET := iphone:clang:9.3:6.0
ARCHS := armv7
DEBUG ?= 0

# Device used by `make install` (Theos) - overridden by tools/ipad.ps1 anyway
THEOS_DEVICE_IP ?= 192.168.137.17
THEOS_DEVICE_USER ?= root

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := Browser

# woff2 decoder (C++) and the brotli decoder it needs (C); fetched by CI into vendor/
WOFF2_FILES := vendor/woff2/src/woff2_dec.cc vendor/woff2/src/woff2_common.cc vendor/woff2/src/woff2_out.cc \
               vendor/woff2/src/table_tags.cc vendor/woff2/src/variable_length.cc
BROTLI_FILES := $(wildcard vendor/brotli/c/common/*.c) $(wildcard vendor/brotli/c/dec/*.c)
# libwebp decoder (encoder dsp files are removed by CI)
WEBP_FILES := $(wildcard vendor/libwebp/src/dec/*.c) $(wildcard vendor/libwebp/src/dsp/*.c) $(wildcard vendor/libwebp/src/utils/*.c)

Browser_FILES := $(wildcard src/*.m) $(wildcard src/*/*.m) $(wildcard src/*/*.mm) \
                 vendor/mbedtls_glue.c \
                 $(wildcard vendor/mbedtls/library/*.c) \
                 $(WOFF2_FILES) $(BROTLI_FILES) $(WEBP_FILES)

Browser_FRAMEWORKS := UIKit Foundation CoreGraphics QuartzCore Security

# Flags for every C-family file (also the vendored mbedTLS sources)
Browser_CFLAGS := -Isrc -Isrc/Net -Isrc/UI -Isrc/Model \
                  -Ivendor -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
                  -Ivendor/woff2/include -Ivendor/brotli/c/include -Ivendor/libwebp -Ivendor/libwebp/src \
                  -Os -fvisibility=hidden \
                  -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                  -Wno-deprecated-declarations -Wno-unknown-warning-option \
                  -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# C++ (woff2) and Objective-C++ (the font converter wrapper)
Browser_CCFLAGS := -std=c++11 -stdlib=libc++ -fno-exceptions -fno-rtti -Wno-unused-parameter
Browser_OBJCCFLAGS := -std=c++11 -stdlib=libc++ -fobjc-arc

# Objective-C only: ARC; APIs newer than iOS 6.0 are warnings here and turned into errors for our own
# sources by the pragma in src/BRCommon.h (vendored code only warns).
Browser_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

Browser_LDFLAGS := -lz -lc++ -lc++abi

# Entitlements: dynamic-codesigning switches on the Nitro JIT inside UIWebView on jailbroken devices.
Browser_CODESIGN_FLAGS := -SResources/entitlements.plist

include $(THEOS)/makefiles/application.mk

# The iOS 9.3 SDK places the NSURL* classes (NSURLCache, NSCachedURLResponse, NSURLProtocol, ...) in
# CFNetwork, so the linker binds them to an implicit CFNetwork dependency. On iOS 6 those classes live
# in Foundation and dyld aborts at launch ("Symbol not found ... Expected in CFNetwork"). Pointing the
# CFNetwork load command at Foundation makes dyld look them up in Foundation (which re-exports CFNetwork
# on newer systems), then the binary is signed again because the change invalidates the signature.
BROWSER_STAGED_BIN := $(THEOS_STAGING_DIR)/Applications/Browser.app/Browser
after-stage::
	install_name_tool -change /System/Library/Frameworks/CFNetwork.framework/CFNetwork /System/Library/Frameworks/Foundation.framework/Foundation "$(BROWSER_STAGED_BIN)"
	ldid -SResources/entitlements.plist "$(BROWSER_STAGED_BIN)"
