SHELL := $(shell which bash) # Use bash syntax to be consistent
OS_NAME := $(shell uname -s | tr '[:upper:]' '[:lower:]')

ZVM_DEPS_DIR ?= $(shell pwd)/src/deps
ZVM_DEPS_OUT_DIR ?= $(ZVM_DEPS_DIR)

CPU_TARGET ?= native
MARCH_NATIVE = -march=$(CPU_TARGET) -mtune=$(CPU_TARGET)
OPTIMIZATION_LEVEL=-O3 $(MARCH_NATIVE)
CFLAGS_WITHOUT_MARCH = $(OPTIMIZATION_LEVEL) -fno-exceptions -fvisibility=hidden -fvisibility-inlines-hidden


CFLAGS=$(CFLAGS_WITHOUT_MARCH) $(MARCH_NATIVE)

REAL_CC = $(shell which clang-16 2>/dev/null || which clang 2>/dev/null)
REAL_CXX = $(shell which clang++-16 2>/dev/null || which clang++ 2>/dev/null)
CLANG_FORMAT = $(shell which clang-format-16 2>/dev/null || which clang-format 2>/dev/null)

CC = $(REAL_CC)
CXX = $(REAL_CXX)
CCACHE_CC_OR_CC := $(REAL_CC)

CCACHE_PATH := $(shell which ccache 2>/dev/null)

CCACHE_CC_FLAG = CC=$(CCACHE_CC_OR_CC)

ifeq (,$(findstring,$(shell which ccache 2>/dev/null),ccache))
	CMAKE_CXX_COMPILER_LAUNCHER_FLAG := -DCMAKE_CXX_COMPILER_LAUNCHER=$(CCACHE_PATH) -DCMAKE_C_COMPILER_LAUNCHER=$(CCACHE_PATH)
	CCACHE_CC_OR_CC := "$(CCACHE_PATH) $(REAL_CC)"
	export CCACHE_COMPILERTYPE = clang
	CCACHE_CC_FLAG = CC=$(CCACHE_CC_OR_CC) CCACHE_COMPILER=$(REAL_CC)
	CCACHE_CXX_FLAG = CXX=$(CCACHE_PATH) CCACHE_COMPILER=$(REAL_CXX)
endif

CXX_WITH_CCACHE = $(CCACHE_PATH) $(CXX)
CC_WITH_CCACHE = $(CCACHE_PATH) $(CC)


CPU_COUNT = 2
ifeq ($(OS_NAME),darwin)
CPU_COUNT = $(shell sysctl -n hw.logicalcpu)
endif

ifeq ($(OS_NAME),linux)
CPU_COUNT = $(shell nproc)
endif

CPUS ?= $(CPU_COUNT)

.PHONY: libarchive
libarchive:
	cd $(ZVM_DEPS_DIR)/libarchive; \
	./build/autogen.sh; \
	CFLAGS="$(CFLAGS)" $(CCACHE_CC_FLAG) ./configure --disable-shared --enable-static  --with-pic --with-lzma  --disable-bsdtar   --disable-bsdcat --disable-rpath --enable-posix-regex-lib  --without-xml2  --without-expat --without-openssl; \
	make -j${CPUS}; \
	cp ./.libs/libarchive.a $(ZVM_DEPS_OUT_DIR)/libarchive.a;
