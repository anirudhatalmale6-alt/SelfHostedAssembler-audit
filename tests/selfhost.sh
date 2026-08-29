#!/bin/sh
# selfhost.sh — the whole loop, with no gcc and no binutils in it anywhere.
#
#   sh tests/selfhost.sh <build-dir> <path-to-nano_cc-repo>
#
# nano_cc's own source, compiled by nano_cc, assembled by mini-asm, and the
# result made to do it again:
#
#   stage1  = mini-asm assembles nano_cc's --nasm output
#   stage2  = stage1 compiles the same source; mini-asm assembles that
#
# and then three things have to be true, in increasing order of how hard they
# are to satisfy by accident:
#
#   1. stage1 RUNS and compiles a program correctly. A binary that starts is
#      not a compiler; the output is compared against the reference compiler's.
#   2. stage1's assembly output for the compiler source is IDENTICAL to the
#      input stage1 was built from. If it is not, stage1 is a compiler with a
#      bug that only shows up on its own source.
#   3. stage1 and stage2 are byte-for-byte the same BINARY. That is the fixed
#      point: assembling the compiler again, with the compiler that was just
#      assembled, changes nothing.
#
# A compiler can pass 1 and still be wrong. It cannot pass 3 and be wrong in a
# way that survives, because any difference in what it emits for its own source
# lands in the next binary.
#
# The reason this test could not exist before: the compiler has ~19 MB of
# uninitialised globals, and without `resb` they were written out as explicit
# zero bytes -- a 61 MB .asm file that mini-asm quite correctly refused.

set -u
BUILD=$1
NANO=$2
ASM=$BUILD/fixed
FAIL=0

if [ ! -x "$NANO/nano_cc" ]; then
    echo "SKIP selfhost: no nano_cc at $NANO (pass NANOCC=/path/to/simpleCpp-build-fix)"
    exit 0
fi
if [ ! -f "$NANO/nano-libc.h" ]; then
    echo "SKIP selfhost: $NANO has no nano-libc.h"
    exit 0
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$ASM" "$W/mini_asm"
cp "$NANO/nano-libc.h" "$NANO/nano-base.h" "$W/"

# The same source transform selfhost.sh in the compiler repo uses: swap the five
# system includes for the freestanding library.
awk '
  /^#include <(stdio|stdlib|string|ctype|stdarg)\.h>$/ { next }
  /^static FILE \*fout;$/ && !done { print "#include \"nano-libc.h\""; done=1 }
  { print }
' "$NANO/simpleC++.c" > "$W/selfsrc.c"

echo "the compiler compiles its own source, for mini-asm"
( cd "$NANO" && ./nano_cc --minimal --nasm --bss "$W/selfsrc.c" "$W/s1.asm" ) >/dev/null 2>&1 \
    || { echo "FAIL: nano_cc --minimal --nasm --bss rejected its own source"; exit 1; }
echo "         $(wc -l < "$W/selfsrc.c") lines of C -> $(wc -c < "$W/s1.asm") bytes of asm"

echo "stage 1: mini-asm assembles it, with no binutils"
cp "$W/s1.asm" "$W/selfHosted.asm"
( cd "$W" && timeout 120 ./mini_asm ) 2>"$W/err" \
    || { echo "FAIL: mini-asm rejected it"; cat "$W/err"; exit 1; }
mv "$W/a.out" "$W/cc1"
chmod +x "$W/cc1"
echo "         $(wc -c < "$W/cc1") byte compiler, built by an assembler written in assembly"

# 1. it has to actually compile something, and compile it RIGHT.
#
# Both compilers are run from $NANO, on the same file name, because nano_cc
# resolves #include against the working directory -- test.c includes a header
# that only exists there.
for d in test features structs bitwise printf switch casts; do
    [ -f "$NANO/$d.c" ] || continue
    ( cd "$NANO" && "$W/cc1" "$d.c" "$W/got.s" ) >/dev/null 2>&1 \
        || { echo "FAIL stage1 could not compile $d.c"; FAIL=1; continue; }
    ( cd "$NANO" && ./nano_cc "$d.c" "$W/want.s" ) >/dev/null 2>&1
    if cmp -s "$W/want.s" "$W/got.s"; then
        echo "PASS stage1 compiles $d.c to identical assembly"
    else
        echo "FAIL stage1 generated different code for $d.c"
        FAIL=1
    fi
done

echo "stage 2: stage1 compiles the same source, mini-asm assembles that"
( cd "$W" && ./cc1 --minimal --nasm --bss selfsrc.c s2.asm ) >/dev/null 2>&1 \
    || { echo "FAIL: stage1 could not compile the compiler"; exit 1; }

# 2. the assembly it produced for its own source must be what it was built from
if cmp -s "$W/s1.asm" "$W/s2.asm"; then
    echo "PASS stage1's output for the compiler source == the input stage1 was built from"
else
    echo "FAIL stage1 emits different assembly for the compiler than it was built from"
    diff "$W/s1.asm" "$W/s2.asm" | head -10
    FAIL=1
fi

cp "$W/s2.asm" "$W/selfHosted.asm"
rm -f "$W/a.out"
( cd "$W" && timeout 120 ./mini_asm ) 2>"$W/err" \
    || { echo "FAIL: mini-asm rejected stage1's output"; cat "$W/err"; FAIL=1; }
if [ -f "$W/a.out" ]; then
    mv "$W/a.out" "$W/cc2"
    # 3. the fixed point
    if cmp -s "$W/cc1" "$W/cc2"; then
        echo "PASS stage1 binary == stage2 binary, byte for byte ($(wc -c < "$W/cc1") bytes)"
    else
        echo "FAIL the two binaries differ"
        FAIL=1
    fi
fi

exit $FAIL
