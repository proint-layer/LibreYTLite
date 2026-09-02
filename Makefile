ifeq ($(ROOTLESS),1)
THEOS_PACKAGE_SCHEME=rootless
endif

DEBUG=0
FINALPACKAGE=1
ARCHS = arm64
PACKAGE_VERSION = 4.7.0
TARGET := iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTLite
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation SystemConfiguration
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DTWEAK_VERSION=$(PACKAGE_VERSION)
$(TWEAK_NAME)_FILES = $(wildcard *.x Utils/*.m)

# The ELM reverse-engineering harness in re/ is NOT part of the shipping tweak -- it is opt-in
# test tooling. `make package ELM_RE=1` compiles the tracer and defines YTL_ELM_RE; a normal
# `make package` never touches it (the wildcard above is root-only, and re/ is excluded), so
# production builds carry zero trace code. See re/ELM_RE.md.
ifeq ($(ELM_RE),1)
$(TWEAK_NAME)_FILES += re/ELMTrace.x
$(TWEAK_NAME)_CFLAGS += -DYTL_ELM_RE
endif

# Download-manager feasibility probe (re/DownloadRE.x). Opt-in like ELM_RE; a normal build omits it.
# `make package DL_RE=1` -> confirms the app's resolved audio MLFormat URL is range-GET-able today.
ifeq ($(DL_RE),1)
$(TWEAK_NAME)_FILES += re/DownloadRE.x
$(TWEAK_NAME)_CFLAGS += -DYTL_DL_RE
endif

include $(THEOS_MAKE_PATH)/tweak.mk
