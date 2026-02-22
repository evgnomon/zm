SOURCES := $(shell find . -type f \( -name "*.zig" -o -name "*.c" -o -name "*.h"  \)  ! -path "*/.zig-cache/*")
OUTPUT := zig-out/bin/zm
OPTIMIZE ?= ReleaseFast
ENV_FILE := .env

-include $(ENV_FILE)

.PHONY: install clean uninstall build all

.env:
	@touch .env

all: build

build: $(OUTPUT)

$(OUTPUT): $(SOURCES) $(ENV_FILE)
	@zig build -Doptimize=$(OPTIMIZE)
	@touch $(OUTPUT)

install: build
	@cp $(OUTPUT) /usr/bin/zm

uninstall:
	@rm /usr/bin/zm

clean:
	@rm -rf $(OUTPUT)
