# Build harness for netpipe/SelfHostedAssembler using plain binutils (no NASM).
#
#   make fetch    # clone upstream into ./upstream
#   make          # build selfContained, selfHosted and the toy C compiler
#   make check    # run the reproductions from README.md
#   make clean

UP      ?= upstream
BUILD    = build
PY      ?= python3
AS      ?= as
LD      ?= ld
CC      ?= gcc

.PHONY: all fetch check clean

# selfHosted.asm does not currently link (it jumps to an undefined label,
# process_line.done_line), so its failure is reported rather than fatal.
all: $(BUILD)/selfContained $(BUILD)/cc_boot
	-@$(MAKE) --no-print-directory $(BUILD)/selfHosted

fetch:
	@test -d $(UP) || git clone --depth 1 https://github.com/netpipe/SelfHostedAssembler.git $(UP)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.s: $(UP)/%.asm tools/nasm2gas.py | $(BUILD)
	$(PY) tools/nasm2gas.py $< > $@

$(BUILD)/%.o: $(BUILD)/%.s
	$(AS) --64 -o $@ $<

$(BUILD)/selfContained: $(BUILD)/selfContained.o
	$(LD) -o $@ $<

$(BUILD)/selfHosted: $(BUILD)/selfHosted.o
	$(LD) -o $@ $<

# The toy C compiler needs a real C compiler; bootstrap.c supplies its I/O.
$(BUILD)/cc_boot: $(UP)/c-compiler/bootstrap.c $(UP)/c-compiler/compiler.c | $(BUILD)
	$(CC) -w -o $@ $<

check: all
	@sh tests/run.sh $(abspath $(BUILD)) $(abspath $(UP))

clean:
	rm -rf $(BUILD)

.PRECIOUS: $(BUILD)/%.s
