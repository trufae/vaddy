V ?= v
VFLAGS ?= -prod -cc clang -gc boehm
VTESTFLAGS ?= -cc clang -gc boehm -d use_bundled_libgc
PYTHON ?= python3
PREFIX ?= /usr/local
COMPARE_ARGS ?=
CONTAINER_ENGINE ?= docker
ALPINE_OUTPUT ?= dist
ALPINE_BUILD_ARGS ?=

ifeq ($(OS),Windows_NT)
EXEEXT := .exe
endif
TARGET := vaddy$(EXEEXT)

# Homebrew's default pkg-config may still select an obsolete OpenSSL keg.
OPENSSL_PKGCONFIG := $(firstword $(wildcard /opt/homebrew/opt/openssl@3/lib/pkgconfig /usr/local/opt/openssl@3/lib/pkgconfig))
ifneq ($(OPENSSL_PKGCONFIG),)
export PKG_CONFIG_PATH := $(OPENSSL_PKGCONFIG):$(PKG_CONFIG_PATH)
endif

.PHONY: all test integration http2 encode files compatibility bench bench-workers caddy-bench raddy-bench compare alpine alpine-x86_64 fmt clean install
all: $(TARGET)

.build/regex.o: src/regex.cc src/regex.h
	mkdir -p .build
	$(CXX) -std=c++17 -O2 $(shell pkg-config --cflags re2) -c src/regex.cc -o $@

$(TARGET): .build/regex.o $(wildcard src/*.v) $(wildcard src/*.h) v.mod
	$(V) $(VFLAGS) -d use_openssl -o $@ src

test: .build/regex.o
	$(V) $(VTESTFLAGS) -d use_openssl test src

integration: $(TARGET)
	python3 tests/integration.py ./$(TARGET)
	python3 tests/upstream.py ./$(TARGET)
	python3 tests/reload.py ./$(TARGET)

http2: $(TARGET)
	$(PYTHON) tests/http2.py ./$(TARGET) $(HTTP2_REFERENCE)

encode: $(TARGET)
	$(PYTHON) tests/encode.py ./$(TARGET) $(ENCODE_REFERENCE)

files: $(TARGET)
	$(PYTHON) tests/files.py ./$(TARGET) $(FILES_REFERENCE)

# Caddy is supplied explicitly so comparisons record the actual reference version.
compatibility: $(TARGET)
	python3 tests/compatibility.py ./$(TARGET) ./caddy-bench

bench: .build/regex.o
	VADDY_BENCH=1 $(V) -cc clang -gc boehm -cflags '-O3' -d use_openssl src/server_test.v

bench-workers:
	python3 tests/ipc_bench.py

caddy-bench: .build/regex.o
	cd caddy && go build -trimpath -ldflags '-s -w' -o ../caddy-bench ./cmd/caddy

raddy-bench: .build/regex.o
	cd raddy && cargo build --release --locked --bin raddy
	cp raddy/target/release/raddy$(EXEEXT) raddy-bench$(EXEEXT)

compare: $(TARGET) caddy-bench raddy-bench
	python3 tests/compare.py $(COMPARE_ARGS)

# Build and test with musl inside x86-64 Alpine, even from an ARM host.
alpine: alpine-x86_64

alpine-x86_64:
	$(CONTAINER_ENGINE) buildx build --platform linux/amd64 --file build/alpine.Dockerfile \
		--target artifact --output "type=local,dest=$(ALPINE_OUTPUT)" $(ALPINE_BUILD_ARGS) .

fmt:
	$(V) fmt -w src

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/$(TARGET)

clean:
	rm -f vaddy vaddy.exe .build/regex.o
