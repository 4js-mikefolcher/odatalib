# odatalib — build + regression suite.
#
# Requires a Genero toolchain on PATH (FGLDIR set; fglcomp/fglrun available).
#   make compile   compile the library modules to .42m
#   make test      compile lib + helpers + the assert suite and run it (SQLite,
#                  in-memory — no external database). Non-zero exit on failure.
#   make test-portability
#                  compile + run the cross-engine portability suite against a
#                  LIVE database. Select the target with env vars, e.g.:
#                    FGLPROFILE=/opt/fourjs/dbfiles/fglprofile.ora \
#                    ODATA_DB=adventureworks ODATA_CONFIG=adventureworks.odata \
#                    ODATA_SCHEMA=aw make test-portability
#   make clean     remove all .42m
#
# The richer PostgreSQL suite (examples/PgSmokeTest) is run manually; see README.

LIB_DIR  := com/fourjs/odatalib
LIB_MODS := ODataTypes ODataError ODataAuth ODataConfig ODataQuery \
            ODataSerializer ODataSqlProvider ODataFunctionProvider \
            ODataExpand ODataProvider ODataService
EX_MODS  := NorthwindFunctions NorthwindCreate

# Library + example helpers + tests must all resolve via FGLLDPATH.
export FGLLDPATH := $(CURDIR):$(CURDIR)/examples:$(CURDIR)/tests

ODATA_CONFIG ?= adventureworks.odata
ODATA_DB     ?= adventureworks
ODATA_SCHEMA ?= aw

.PHONY: all compile examples test test-portability clean

all: compile

compile:
	@for m in $(LIB_MODS); do \
	    echo "  fglcomp $$m"; \
	    fglcomp -M -Wall $(LIB_DIR)/$$m.4gl || exit 1; \
	done
	@echo "library compiled."

examples: compile
	@for m in $(EX_MODS); do \
	    echo "  fglcomp examples/$$m"; \
	    ( cd examples && fglcomp -M $$m.4gl ) || exit 1; \
	done

test: examples
	@( cd tests && fglcomp -M odata_test.4gl ) || exit 1
	@echo "running regression suite (in-memory SQLite)..."
	@cd examples && FGLGUI=0 TERM=xterm fglrun ../tests/odata_test.42m

test-portability: examples
	@( cd tests && fglcomp -M portability_test.4gl ) || exit 1
	@echo "running portability suite (schema=$(ODATA_SCHEMA) db=$(ODATA_DB))..."
	@cd examples && ODATA_TEST_CONFIG=$(ODATA_CONFIG) ODATA_DB=$(ODATA_DB) \
	    ODATA_SCHEMA=$(ODATA_SCHEMA) FGLGUI=0 TERM=xterm \
	    fglrun ../tests/portability_test.42m

clean:
	@find . -name '*.42m' -delete
	@echo "cleaned."
