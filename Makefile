# codesystem: the extension (PGXS), plus development targets for the engine and the loaders, which need no PostgreSQL.
EXTENSION    = codesystem
EXTVERSION   = 0.2.0
MODULE_big   = codesystem
OBJS         = codesystem.o engine/cs_pattern.o
DATA         = codesystem--0.1.0.sql codesystem--0.1.0--0.2.0.sql codesystem--0.2.0.sql
REGRESS      = define types hierarchy revisions derive pattern
PG_CPPFLAGS  = -I engine -std=c99 -Wall -Wno-declaration-after-statement -DEXTVERSION=$(EXTVERSION)
EXTRA_CLEAN  = build $(filter-out data/prepared/uk_sic_% data/prepared/nace_rev2.csv data/prepared/gss_entity_types.csv,$(wildcard data/prepared/*))
PG_CONFIG   ?= pg_config
PGXS        := $(shell $(PG_CONFIG) --pgxs 2>/dev/null)
ifneq ($(PGXS),)
include $(PGXS)
else
# no PostgreSQL development files found: the engine and loader targets below still work
.DEFAULT_GOAL := test
endif

# The install script of 0.2.0 is the install script of 0.1.0 followed by the upgrade: committed, and checked to be exactly that.
codesystem--0.2.0.sql: codesystem--0.1.0.sql codesystem--0.1.0--0.2.0.sql
	cat codesystem--0.1.0.sql codesystem--0.1.0--0.2.0.sql > $@

.PHONY: verify-install-script
verify-install-script:
	@cat codesystem--0.1.0.sql codesystem--0.1.0--0.2.0.sql | cmp - codesystem--0.2.0.sql || { echo "codesystem--0.2.0.sql is out of date: run make codesystem--0.2.0.sql" >&2; exit 1; }

CC     ?= cc
CFLAGS_ENGINE = -std=c99 -Wall -Wno-declaration-after-statement -Wpedantic -D_POSIX_C_SOURCE=200809L -O1 -I engine
ENGINE_TESTS  = lists listbuild pattern parts

.PHONY: test engine-test tools-test prepare sanitize

test: engine-test tools-test

build/test_cs_%: test/test_cs_%.c engine/cs_pattern.c engine/cs_pattern.h
	@mkdir -p build
	$(CC) $(CFLAGS_ENGINE) -o $@ test/test_cs_$*.c engine/cs_pattern.c

engine-test: $(addprefix build/test_cs_,$(ENGINE_TESTS))
	@for t in $(ENGINE_TESTS); do printf '%-9s ' $$t; ./build/test_cs_$$t | tail -1 || exit 1; done

tools-test:
	python3 -m unittest discover -s test -p 'test_prepare.py'

# the prepared form of the source files (needs data/raw/, see data/SOURCES.md)
prepare: data/prepared/nace_rev2.csv data/prepared/uk_soc_2020.csv

data/prepared/isic_rev4.csv: data/raw/ISIC_Rev_4_english_structure.Txt tools/prepare_isic.py tools/csmodel.py
	@mkdir -p data/prepared
	python3 tools/prepare_isic.py $< $@

data/prepared/nace_rev2.csv: data/raw/NACERev.2_EN_CTI_20070214_131821_utf8.csv tools/prepare_nace.py tools/csmodel.py
	@mkdir -p data/prepared
	python3 tools/prepare_nace.py $< $@

data/prepared/uk_soc_2020.csv: data/raw/Extended_SOC_framework.csv tools/prepare_soc.py tools/csmodel.py
	@mkdir -p data/prepared
	python3 tools/prepare_soc.py $< data/prepared/uk_soc_2020.csv data/prepared/uk_soc_2020_extended.csv

data/prepared/isco_08.csv: data/raw/ISCO-08_EN.csv tools/prepare_isco.py tools/csmodel.py
	@mkdir -p data/prepared
	python3 tools/prepare_isco.py $< $@

# the engine tests under AddressSanitizer and UBSan (needs a platform where they run, such as Linux).
sanitize:
	@mkdir -p build
	@for t in $(ENGINE_TESTS); do \
	  $(CC) -std=c99 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=undefined -D_POSIX_C_SOURCE=200809L -I engine \
	    -o build/san_$$t test/test_cs_$$t.c engine/cs_pattern.c && printf '%-9s ' $$t && ASAN_OPTIONS=detect_leaks=0 ./build/san_$$t | tail -1 || exit 1; \
	done
