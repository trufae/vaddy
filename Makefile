V ?= v
VFLAGS ?= -prod -cc clang -gc boehm
PREFIX ?= /usr/local
COMPARE_ARGS ?=

# Homebrew's default pkg-config may still select an obsolete OpenSSL keg.
OPENSSL_PKGCONFIG := $(firstword $(wildcard /opt/homebrew/opt/openssl@3/lib/pkgconfig /usr/local/opt/openssl@3/lib/pkgconfig))
ifneq ($(OPENSSL_PKGCONFIG),)
export PKG_CONFIG_PATH := $(OPENSSL_PKGCONFIG):$(PKG_CONFIG_PATH)
endif

.PHONY: all test integration bench bench-workers caddy-bench compare fmt clean install
all: vaddy

vaddy: $(wildcard src/*.v) src/platform.h v.mod
	$(V) $(VFLAGS) -d use_openssl -o $@ src

test:
	$(V) -d use_openssl test src

integration: vaddy
	python3 tests/integration.py ./vaddy

bench:
	VADDY_BENCH=1 $(V) -cc clang -gc boehm -cflags '-O3' -d use_openssl src/server_test.v

bench-workers:
	python3 tests/ipc_bench.py

caddy-bench:
	cd caddy && go build -trimpath -ldflags '-s -w' -o ../caddy-bench ./cmd/caddy

compare: vaddy caddy-bench
	python3 tests/compare.py $(COMPARE_ARGS)

fmt:
	$(V) fmt -w src

install: vaddy
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 vaddy $(DESTDIR)$(PREFIX)/bin/vaddy

clean:
	rm -f vaddy
