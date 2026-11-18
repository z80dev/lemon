# Builds the descriptor-bound file helper used by LemonCore.ConfinedFS
# (c_src/lemon_confined_fs.c). Run by the :elixir_make compiler, which sets
# MIX_APP_PATH to this app's build directory; the helper lands in its priv/.
#
# LEMON_CONFINED_FS_REQUIRED=1 (set by mix.exs inside the Lemon umbrella)
# makes a failed build fail `mix compile`. Otherwise (lemon_core as a Hex
# dependency) a missing or failing C compiler leaves no helper: ConfinedFS
# then reports unavailable and its callers fail closed.
MIX_APP_PATH ?= $(CURDIR)
LEMON_CONFINED_FS_REQUIRED ?= 1
PRIV_DIR := $(MIX_APP_PATH)/priv
HELPER := $(PRIV_DIR)/lemon_confined_fs
STAMP := $(PRIV_DIR)/.lemon_confined_fs.platform
SOURCE := c_src/lemon_confined_fs.c
PLATFORM := $(shell uname -sm)
CC ?= cc
HELPER_CFLAGS := -std=c11 -O2 -Wall -Wextra -D_FORTIFY_SOURCE=2 -fstack-protector-strong

all: $(HELPER)

# A helper built for another platform (for example in a copied tree) is
# rebuilt rather than trusted.
ifneq ($(PLATFORM),$(shell cat "$(STAMP)" 2>/dev/null))
.PHONY: $(HELPER)
endif

$(HELPER): $(SOURCE) Makefile
	@mkdir -p "$(PRIV_DIR)"
	@rm -f "$@" "$(STAMP)"
	@if $(CC) $(HELPER_CFLAGS) $(CFLAGS) -o "$@.$$$$.tmp" $(SOURCE); then \
	  mv -f "$@.$$$$.tmp" "$@" && printf '%s' '$(PLATFORM)' > "$(STAMP)"; \
	else \
	  rm -f "$@.$$$$.tmp"; \
	  if [ "$(LEMON_CONFINED_FS_REQUIRED)" = "1" ]; then exit 1; fi; \
	  echo "warning: lemon_core: could not build priv/lemon_confined_fs; LemonCore.ConfinedFS is unavailable and confined file operations will fail closed" >&2; \
	fi

clean:
	rm -f "$(HELPER)" "$(STAMP)"

.PHONY: all clean
