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

Browser_FILES := $(wildcard src/*.m) $(wildcard src/*/*.m) \
                 vendor/mbedtls_glue.c \
                 $(wildcard vendor/mbedtls/library/*.c)

Browser_FRAMEWORKS := UIKit Foundation CoreGraphics QuartzCore Security

# Flags for every C-family file (also the vendored mbedTLS sources)
Browser_CFLAGS := -Isrc -Isrc/Net -Isrc/UI \
                  -Ivendor -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
                  -Os -fvisibility=hidden \
                  -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                  -Wno-deprecated-declarations -Wno-unknown-warning-option \
                  -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# Objective-C only: ARC; APIs newer than iOS 6.0 are warnings here and turned into errors for our own
# sources by the pragma in src/BRCommon.h (vendored code only warns).
Browser_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

Browser_LDFLAGS := -lz

# Entitlements: dynamic-codesigning switches on the Nitro JIT inside UIWebView on jailbroken devices.
Browser_CODESIGN_FLAGS := -SResources/entitlements.plist

include $(THEOS)/makefiles/application.mk
