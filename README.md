# SelfHostedAssembler — build harness + audit

Companion to [`netpipe/SelfHostedAssembler`](https://github.com/netpipe/SelfHostedAssembler).

Two things live here:

1. **`tools/nasm2gas.py`** — a translator for the NASM subset those `.asm` files
   use, so both assemblers can be **built and run with plain binutils** (`as` +
   `ld`), no NASM needed. It is deliberately faithful: it fixes nothing, so a
   bug in the `.asm` is still a bug in the binary.
2. **This document** — what happens when you actually run them, what was wrong,
   and how the answer to *"can we compile `nano_cc` with this?"* went from
   **not yet** to **yes, for the output**.

```sh
make            # builds selfContained + selfHosted + the toy C compiler
make check      # runs the reproductions below
make m1         # builds the corrected assembler from fixed/
make golden     # byte-compares its output against GNU as
make bootstrap  # C -> nano_cc -> mini-asm -> running binary, no gcc, no binutils
                # (pass NANOCC=/path/to/simpleCpp-build-fix)
```

**The loop closes.** `fixed/selfContained.asm` assembles `nano_cc`'s output into
a working binary with no gcc and no binutils involved, and everything it emits
is byte-for-byte identical to GNU as. See [section 6](#6-m1--the-corrected-assembler),
[section 7](#7-a2--memory-operands-extended-registers-shifts) and
[section 8](#8-a3--the-loop-closes).

---

## TL;DR

| Component | State | Can it build `nano_cc`? |
|---|---|---|
| `selfContained.asm` | Runs. Fails on the first instruction of its own documented subset. | No |
| `selfHosted.asm` | Does not assemble — jumps to a label that is never defined. Under that, the encoders are labelled placeholders that emit no bytes. | No |
| `c-compiler/compiler.c` | Emits syntactically invalid NASM; `*` and `/` return 0. | No |
| `shlr-patch/*` | Adds `shl`/`shr` table entries, but on top of the above. | No |

Applying the shl/shr patch is not the blocker. Each of the three components
fails well before shifts matter.

---

## 1. Reproductions

> **Note.** Upstream HEAD now carries the M1 fix — netpipe applied the patch and
> pushed it as commit `72a37b0 "compiles"`, and the history before that was
> rewritten, so the original commits are no longer fetchable. The pre-M1 sources
> are therefore vendored in `original/` and `make check` runs against those, so
> the findings below stay checkable. `make fetch` still clones current upstream
> into `upstream/` for the patch to apply to.

Run against the pre-M1 sources, no edits to any `.asm` or `.c`.

### 1.0 `selfHosted.asm` does not assemble

```
ld: selfHosted.o: in function `process_line':
    undefined reference to `process_line.done_line'
```

Line 168 is `je .done_line`, and `.done_line` is never defined anywhere in the
file — the label the author meant is `.next_line` or `.done`. NASM rejects this
for the same reason. So `selfHosted.asm` has never been built in its current
state.

### 1.1 `selfContained` cannot assemble `mov rax, 60`

```
$ cat selfHosted.asm
_start:
mov rax, 60
xor rdi, rdi
syscall

$ ./selfContained
Error:
$ echo $?
1
$ ls a.out
ls: cannot access 'a.out': No such file or directory
```

`mov r64, imm32` is the very first form in its own opcode table.

### 1.2 A 4-letter mnemonic segfaults

```
$ printf 'foo:\ncall foo\n' > selfHosted.asm
$ ./selfContained
Segmentation fault (core dumped)
```

### 1.3 Fed its own intended input, it hangs

```
$ cp ../selfHosted.asm . && timeout 5 ./selfContained
$ echo $?
124            # timed out — infinite loop
```

### 1.4 The toy C compiler emits invalid assembly and wrong arithmetic

```
$ printf 'x = 2 + 3 * 4;\ny = x - 1;\n' | ./cc_boot
...
mov rax, 4
mov rcx, [rsp]
add rsp, 8
mov rax, rcx
mov rax, 0          <-- 3 * 4 evaluated to 0
...
mov [vars + 0]      <-- no source operand; not valid NASM
mov rax, mov [vars + 16]   <-- two mnemonics on one line
```

`x` is stored at `vars+0` and read back from `vars+16`. `2 + 3*4` compiles to
the value `2`.

---

## 2. Root causes

### 2.1 `selfContained.asm`

**(a) `call emit_byte` followed by a raw `db` — 10 of the 17 emit sites.**

```asm
    call emit_byte
    db 0x48            ; intended: "now emit a REX.W byte"
    mov rdi, r14
    call emit_byte
```

`db 0x48` is not data here — it is planted in the middle of the instruction
stream and *executes*. Disassembling the linked binary:

```
 406:   call   7d1 <emit_byte>
 40b:   rex.W                     <-- the 0x48, now a prefix on the next insn
 40c:   mov    %r14,%rdi
 40f:   call   7d1 <emit_byte>
```

So the REX.W byte is never written to the output, and the first `emit_byte`
call runs with whatever `rdi` happened to hold. Every encoded instruction gets
a garbage first byte. The intent was `mov rdi, 0x48` / `call emit_byte`.
Affects `parse_alu`, `parse_mov` (both paths), `parse_jcc`, `parse_call`,
`parse_ret`, `parse_sys`.

**(b) `is_register` never returns — all eight `ret`s are commented out.**

```asm
.r0: mov eax, 0 ; ret
.r1: mov eax, 1 ; ret
...
.r7: mov eax, 7 ; ret
```

The `;` makes `ret` a comment, so `.r0` falls into `.r1` … into `.r7`, and
`.r7` falls straight into the next function, `is_number`. Confirmed by
disassembly — there is no `ret` anywhere between `.r0` and `is_number`. Every
register name resolves to the same value.

**(c) `parse_instruction` mis-restores the read pointer.**

```asm
.copy_loop:  ...  inc r13  ...      ; advances r13 once per *letter* copied
.done_copy:
    sub r13, 4                      ; always subtracts 4
```

For a 3-letter mnemonic (`mov`, `add`, `xor`, `jmp`) `r13` advanced by 3 but 4
is subtracted, so `r13` ends up one byte *before* the mnemonic — on the
previous newline. The `.skip_mnem` loop then stops immediately, the mnemonic is
never consumed, and `get_token` returns `"mov"` as the first operand.
`is_register("mov")` fails → `error_exit`. **This is the failure in 1.1.**

**(d) `parse_alu` and the shl/shr patch overwrite `r13`, the input pointer.**

```asm
    call is_register
    mov r13, rax        ; r13 is the source read pointer!
```

Once a register index (0-7) lands in `r13`, the next `process_line` dereferences
a near-null pointer. **This is the segfault in 1.2.**

**(e) `pc_vaddr` and `out_ptr` disagree.** `parse_mov`'s reg,reg path emits 3
bytes but advances `pc_vaddr` by 7. Every label address computed after the first
`mov r64, r64` is wrong, so every `jmp`/`je`/`call` displacement is wrong.

**(f) Any line whose first character is `s`, `g`, `e` or `r` is discarded.**

```asm
    cmp al, 's'  ; section
    je .skip_to_nl
    cmp al, 'g'  ; global
    je .skip_to_nl
    cmp al, 'e'  ; extern/equ
    je .skip_to_nl
    cmp al, 'r'  ; resb/resq
    je .skip_to_nl
```

That check runs on the first non-whitespace character of the line, which for an
indented instruction is the first letter of the *mnemonic*. So `sub`, `syscall`,
`ret` — and `shl`/`shr`, the whole point of the patch — are silently dropped.
The directive test needs to match the whole word, not one character.

**(g) The symbol table holds 170 entries (`4096 / 24`), not the 256 the comment
claims, and there is no overflow check.**

### 2.2 `selfHosted.asm`

It does not assemble at all: `process_line` contains `je .done_line` for a label
that does not exist (1.0). Once that is corrected, the encoders are placeholders,
as the file itself says:

```asm
; Placeholder emitters to satisfy structure.
emit_modrm_prefix:
    add qword [pc_vaddr], 3
    ret
emit_alu_op:
    add qword [pc_vaddr], 3
    ret
emit_jump:
    add qword [pc_vaddr], 5
    ret
```

Nothing is ever written to `out_buf` except the `ret` opcode, so its `a.out` is
an ELF header plus a handful of `0xC3` bytes. Additionally `is_label` does
`mul rcx` with the *hash* in `rax` instead of the symbol count, producing a wild
`sym_tbl` pointer.

The shl/shr patch for this file adds

```asm
parse_shift:
    add qword [pc_vaddr], 4
    jmp end_instr
```

which reserves 4 bytes and emits none — consistent with the other stubs, but it
adds no capability. It also dispatches on `'s'` inside `is_instr`, which is
unreachable because `process_line` already discarded every `s…` line (2.1f).

### 2.3 `c-compiler/compiler.c`

- `find_var` is broken: `var_start[id] = var_len[id] = 0;` zeroes the name slot,
  the name is then written at `var_names[var_count * 64 + k]` (`var_count` was
  already incremented, so it lands one slot too far), and lookups compare
  against `var_names[var_start[i] + k]` where `var_start[i]` is always 0. Every
  reference to an existing variable allocates a *new* one — hence store at
  `vars+0`, load from `vars+16`.
- Assignment emits `STR_MOV_VARS` with no source operand, so `mov [vars + 0]`.
- Variable loads emit `STR_MOV_RAX` *and* `STR_MOV_VARS`, so
  `mov rax, mov [vars + 16]`.
- `*` and `/` are stubs that emit `mov rax, 0`.
- No `if`, `while`, function definitions, `print`, pointers, arrays or strings —
  the parser handles `name = expr;` and blocks only. It cannot compile itself,
  and `bootstrap.c` needs a real C compiler regardless.

The shl/shr patch replaces the `*`/`/` stubs with shift sequences for
`v ∈ {0,1,2,3,4,5,8,10}` on multiply and `{1,2,4,8}` on divide, and keeps
`mov rax, 0` for every other constant and for *all* non-constant operands. So
`a * 6` and `a * b` still silently produce 0. `last_was_const` is also never
cleared by the `(` branch of `factor()`, so a parenthesised sub-expression
inherits a stale constant from inside it.

---

## 3. Can `nano_cc` be compiled by this?

Three independent gaps, in increasing size:

**(a) Nothing here can compile C.** `compiler.c` handles `name = expr;`.
`nano_cc` is 1489 lines using `calloc`, `fopen`, `fprintf`, `strcmp`,
`va_list`, structs, pointers, arrays and function pointers. That is not a patch;
it is a different program.

**(b) The assembler cannot assemble `nano_cc`'s *output* either.** Across the
six demo programs, `nano_cc` emits **31 distinct mnemonics**:

```
mov push lea pop call xor add ret leave jmp test jz sub cmp movsx movzx
sete setg idiv cqo setl neg je syscall and shl or setle sar not jnz imul
```

The assembler's table has 14 entries and supports only `reg,reg`, `reg,imm` and
`label` operands. **No memory operand form exists at all** — and 2138 of the
emitted instructions are `mov`, the overwhelming majority of them to or from
memory (`mov [rbp-8], rax`). `push`/`pop`/`lea`/`leave`/`idiv`/`imul`/`cqo`/
`movsx`/`movzx`/`setcc` are all absent too.

**(c) Neither assembler can assemble its own source.** By its own supported
list, `selfContained.asm` uses **19 mnemonics it does not support**, in 101 of
its 532 instructions (`push`, `pop`, `lea`, `test`, `movzx`, `imul`, `mul`,
`inc`, `dec`, `or`, `rep`, `js`, `jz`, `jnz`, `jb`, `ja`, `jbe`, `jge`, `shl`)
— plus 8-bit registers, memory operands, `dw`/`dd`/`dq`, `equ`, `align` and
`section`. `selfHosted.asm` uses 10 unsupported mnemonics in 25 of its 194
instructions. The "self-hosting" property does not hold in either file today.

---

## 4. What a working path looks like

Roughly in dependency order. Each step is independently testable.

1. **Make `selfContained` correct for the subset it already claims.** Fix
   2.1(a)–(g). Add a golden test: assemble a small program, compare the emitted
   bytes against `as`/`objdump` output for the same source. This is the
   foundation — everything else is worthless without it.
2. **Widen the encoder** to memory operands (`[reg]`, `[reg+disp]`,
   `[label]`), 8-bit registers, `push`/`pop`/`lea`/`test`/`inc`/`dec`/`neg`/
   `not`/`shl`/`shr`/`sar`/`or`, `movzx`/`movsx`, `setcc`, `imul`/`idiv`/`cqo`,
   `leave`, and the full `jcc` set. This is what it takes to accept
   `nano_cc`-shaped output.
3. **Add `.bss`/`.data` sections and 64-bit immediates** so real programs, not
   just single code blobs, can be produced.
4. **Teach `nano_cc` a `-masm=nasm` output mode.** Its backend already emits
   Intel syntax; switching `.intel_syntax noprefix` / `.zero` / `.quad` to NASM
   `section` / `resb` / `dq` is a contained change. That gets
   `nano_cc program.c | selfContained` working end to end.
5. **Only then** is "assemble `nano_cc`'s own output with `selfContained`"
   reachable — and it needs step 2 finished, because `nano_cc`'s output uses
   every form listed there.

Compiling `nano_cc`'s *source* with `c-compiler/compiler.c` is not on this path
and I would not recommend attempting it; `nano_cc` already is the C compiler.

---

## 5. `tools/nasm2gas.py`

Handles what these files use: `section` / `global` / `equ` / `align`,
`db`/`dw`/`dd`/`dq` (including string operands), `resb`/`resq`, NASM local
labels (`.loop` → `owner__loop`), NASM character constants (`'rax'` → the packed
integer), `byte [x]` → `byte ptr [x]`, and bare-symbol operands → `offset sym`
(GAS Intel syntax reads a bare symbol as memory contents; NASM reads it as the
address — that difference alone silently breaks every `mov rdi, in_path`).

```sh
python3 tools/nasm2gas.py selfContained.asm > selfContained.s
as --64 -o selfContained.o selfContained.s
ld  -o selfContained selfContained.o
```

It is a build aid, not a general NASM implementation.

---

## 6. M1 — the corrected assembler

`fixed/selfContained.asm` is `selfContained.asm` with every fault from section 2.1
fixed. `fixed/selfContained.patch` carries the change as a unified diff, ready to apply
to current upstream:

```sh
cd SelfHostedAssembler
patch -p1 < selfContained.patch
```

Since upstream already contains M1, that patch is now the **A2** change alone
(section 7).

### 6.1 Result

```
$ make golden
  bytes: 153, identical to GNU as
PASS golden1: byte-identical to GNU as, runs, exits 42
  bytes: 160, identical to GNU as
PASS golden2: byte-identical to GNU as, runs, exits 55
PASS regression: 'mov rax, 60' assembles (used to error)
PASS regression: 'call foo' assembles (used to segfault)
PASS regression: s/r lines reach the dispatcher (shl reported, not dropped)
```

`golden1` prints `hello from mini-asm` and exits 42. `golden2` sums 1..10 through
a backward loop and exits 55. Both cover `mov reg,imm` / `mov reg,reg`, `add`,
`sub`, `cmp`, `xor`, `and`, `jmp`, `je`, `jne`, `jl`, `jg`, `call`, `ret`,
`syscall`, `db` with strings and numbers, forward and backward label references,
nested calls, and all eight encodable registers.

### 6.2 Why byte-comparison and not just "does it run"

A program that runs proves the paths it happens to take. It does not prove the
encoder. Each golden test therefore assembles the same source twice — once with
mini-asm, once with `as` + `ld` — and requires the two byte streams to match
exactly.

One wrinkle: mini-asm always encodes branches as `rel32`, while GAS relaxes short
ones to `rel8`. Both are correct; they are just different choices. The reference
build passes `--long-jumps` to `nasm2gas.py`, which emits `jmp.d32` / `je.d32` so
that both assemblers make the same choice and the comparison stays meaningful.

### 6.3 What changed

| # | Fault | Fix |
|---|---|---|
| a | `call emit_byte` followed by a bare `db 0xNN`, which executed as a prefix instead of being emitted (10 sites) | `mov rdi, 0xNN` then `call emit_byte` |
| b | `is_register`'s eight `ret`s were all commented out by `;`, so `.r0` fell through to `is_number` | each `ret` on its own line |
| c | `parse_instruction` advanced `r13` per letter then always subtracted 4 | new `word_key` builds the lookup key without moving `r13`; the mnemonic is consumed exactly once |
| d | `parse_alu` wrote a register index into `r13`, the input read pointer | parser scratch moved to `r12`/`r15`/`rbp`; a register contract is documented at the top of the file |
| e | `parse_mov` counted 7 bytes for `mov reg,reg`, which emits 3 | each operand form advances `pc_vaddr` by its true size |
| f | `parse_alu` used `r14`, the input end pointer, to hold the opcode | opcode held in `rbp` |
| g | any line starting with `s`, `g`, `e` or `r` was discarded, taking `sub`, `syscall`, `ret`, `shl`, `shr` with it | directives matched as whole words against a `directive_table` |
| h | `find_symbol` clobbered `rcx`, the token length, before `parse_mov` called `is_number` | loop scratch moved to `r10` |
| i | symbol lookup compared hashes only | entries store the name length too, and both must match |
| j | no symbol table bounds check (`4096/24` = 170 entries, comment claimed 256) | `sym_max` check with a clear error |
| k | an unrecognised line was silently skipped | reported as `Error: unknown mnemonic: xxxx` |
| l | `name db ...` was not handled | defines the symbol at the current address, then emits the bytes |
| m | `db` could not hold a string containing a space or comma | strings scanned directly off the read pointer |
| n | a parser stopping mid-line left the rest to be parsed as another instruction | `.is_instr` skips to end of line |

### 6.4 Behaviour on the original `selfHosted.asm`

```
$ ./fixed          # input is selfHosted.asm
Error: unknown mnemonic: test
```

Previously this hung forever. It now names the first instruction it cannot
encode, which is exactly the M2 work list: `test`, `lea`, `push`, `pop`,
`movzx`, `inc`, `dec`, `or`, `imul`, `mul`, `rep`, and the `jb`/`ja`/`jbe`/`jge`
family, plus memory operands and 8-bit registers.

### 6.5 Not in M1

Deliberately out of scope, and still true of `fixed/`:

- No memory operands, no 8-bit registers, no `push`/`pop`/`lea`/`test`. That is M2.
- Labels are global; NASM's `.local` scoping is not implemented.
- `mov reg, imm` takes a 32-bit immediate only.
- Symbols are matched on a DJB2 hash plus length, not the full name.
- Everything is emitted into one flat `PT_LOAD`; there is no `.data`/`.bss`
  separation. That is M3.
- It still cannot assemble its own source — that needs M2 first.

---

## 7. A2 — memory operands, extended registers, shifts

The design brief for this one came from netpipe: keep the instruction set small
and portable, and use shifts instead of `imul`/`idiv`. That reframed M2 usefully.
The blocker was never a long list of missing instructions — it was that the
assembler had **no memory operand form at all**, so nothing could load or store a
variable. The upstream `c-compiler/` emits `mov [rsp], rax` and
`mov [vars + 0], rax`, neither of which the assembler could encode.

So A2 adds one shared ModR/M encoder rather than nineteen instructions.

### 7.1 What it accepts now

```
registers   rax rcx rdx rbx rsp rbp rsi rdi r8..r15, and al cl dl bl
operands    reg · imm32 · label
            [reg] · [reg + N] · [reg - N] · [rip + label] · [label]
mov         reg,imm · reg,reg · mem,reg · reg,mem
alu         add or and sub xor cmp, in all of the above directions,
            plus reg,imm8 and reg,imm32
shifts      shl shr sar, by 1, by imm8, and by cl
branches    jmp · je/jz · jne/jnz · jl jle jg jge jb jbe ja jae js jns
            call · ret · syscall · db
```

```
byte access mov al, [mem] · mov [mem], al   (also cl, dl, bl)
```

Still deliberately absent: `[base + index]`, scaled indexes, 16/32-bit operand
sizes, `ah`/`ch`/`dh`/`bh`, and an immediate written straight to memory.

The byte forms were added after C-min: they are the one thing on the
synthesise-instead list that genuinely cannot be synthesised. A 1-byte store
built from 8-byte operations means reading and rewriting the seven bytes around
it, which may not be mapped and is not the same operation. `char`, strings and
`printf` all depend on it.

### 7.2 Result

```
$ make golden
  bytes: 153, identical to GNU as
PASS golden1: byte-identical to GNU as, runs, exits 42
  bytes: 160, identical to GNU as
PASS golden2: byte-identical to GNU as, runs, exits 55
  bytes: 194, identical to GNU as
PASS golden3: byte-identical to GNU as, runs, exits 42
  bytes: 1013, identical to GNU as
PASS golden4: byte-identical to GNU as, runs, exits 0
  bytes: 311, identical to GNU as
PASS subset: byte-identical to GNU as, runs, exits 42
  bytes: 208, identical to GNU as
PASS golden5: byte-identical to GNU as, runs, exits 42
  bytes: 388, identical to GNU as
PASS golden6: byte-identical to GNU as, runs, exits 42
PASS regression: 'mov rax, 60' assembles (used to error)
PASS regression: 'call foo' assembles (used to segfault)
PASS regression: s/r lines assemble (sub, shl, shr, syscall, ret)
PASS regression: an unknown mnemonic is reported, not skipped
```

`golden3` is a running program that exercises the new forms and exits 42.
`golden4` is 935 bytes of pure encoding coverage — it exits immediately and the
rest exists only to be byte-compared: all sixteen registers as both operand and
memory base, every displacement class, all six ALU ops in all three directions,
all three shifts in all three forms, every conditional branch, and RIP-relative
loads and stores.

`golden6` covers 64-bit immediates, and it is worth explaining why it needed
to exist. `mov reg, imm32` **sign-extends** its 32-bit field to 64 bits, so an
immediate outside -2^31 .. 2^31-1 cannot use that form — the processor would
load a different number than the source asked for. The assembler emitted the
short form unconditionally:

```
mov rax, 2147483648
  mini-asm  48 c7 c0 00 00 00 80              -> rax = -2147483648
  GNU as    48 b8 00 00 00 80 00 00 00 00     -> rax =  2147483648
```

Nothing about that fails loudly. The program assembles, links and runs; it
simply computes with the wrong number. It surfaced when a C program printed
`2147483648` as `-2147483648` after going through this assembler. The fix adds
the 10-byte `REX.W B8+rd io` form and — just as importantly — keeps choosing
the 7-byte form whenever the value fits, because binutils does, and this test
is a byte comparison against binutils.

### 7.3 Encoding corners that the coverage test exists to catch

None of these announce themselves — each one silently produces a wrong address
or a wrong instruction:

- **`[rbp]` and `[r13]` cannot use the `mod=00` form.** That bit pattern means
  RIP-relative in 64-bit mode, so both always carry an explicit displacement,
  even when it is zero.
- **`[rsp]` and `[r12]` need a SIB byte.** `rm=100` means "a SIB follows", so a
  plain `[rsp]` is encoded as `mod=00 rm=100` plus SIB `0x24`.
- **`shl reg, 1` has its own shorter opcode** (`D1 /4`, not `C1 /4 ib`), and
  binutils uses it.
- **`<op> rax, imm32` has an accumulator form** with no ModR/M byte at all
  (`ADD`=`05`, `OR`=`0D`, `AND`=`25`, `SUB`=`2D`, `XOR`=`35`, `CMP`=`3D`), one
  byte shorter, and binutils uses that too.
- **`reg, mem` and `mem, reg` are different opcodes**, `op` and `op+2`.
- **The `reg` field and the `r/m` field take different REX bits** — `REX.R` and
  `REX.B` respectively — so `add r8, r15` needs both.

The last two of those were caught by the byte comparison, not by anything
running. That is the argument for the comparison in one line.

### 7.4 What is left before `nano_cc` output can be assembled

Across the six demos, `nano_cc` still emits these, and every one of them is on
netpipe's synthesise-instead list rather than the implement-in-the-assembler list:

```
push pop lea leave test movzx movsx sete setg setl setle neg not imul idiv cqo
```

**That is now done** — `nano_cc --minimal` synthesises every one of them. See
`make minimal` in the compiler repo. What remains between the two halves is
assembly *syntax*, not instructions: `nano_cc` emits GNU-as Intel
(`.section`, `.globl`, `.string`, `.zero`, `qword ptr`, `offset`) and mini-asm
reads a NASM subset (`section`, `global`, `db`, no size keywords).

---

## 8. A3 — the loop closes

`make bootstrap` compiles each demo the ordinary way (nano_cc, then gcc to
assemble and link) and again through `nano_cc --minimal --nasm` assembled by
mini-asm alone, and requires the two binaries to behave identically.

```
$ make bootstrap NANOCC=../simpleCpp-build-fix
PASS test: same output as the gcc-assembled build (6700 byte binary)
PASS features: same output as the gcc-assembled build (8156 byte binary)
PASS structs: same output as the gcc-assembled build (7870 byte binary)
PASS bitwise: same output as the gcc-assembled build (8235 byte binary)
PASS printf: same output as the gcc-assembled build (6842 byte binary)
PASS switch: same output as the gcc-assembled build (8584 byte binary)
```

C source in, running ELF out, with no gcc and no binutils anywhere in the path.

### 8.1 What this milestone had to add

**On the assembler side:**

- `p_flags` was `5` (read + execute). Everything lives in one `PT_LOAD`, so a
  program with a writable global faulted on its first store. Now `7`.
- Buffers were 64 KB with **no check that the file fit**. A larger input would
  have assembled the first 64 KB and silently dropped the rest — the worst
  possible failure. Now 1 MB, and it refuses rather than truncating.
- The symbol table held 170 entries. `switch.c` alone emits 147 labels before
  minimal mode adds more. Now 2730.
- **`is_number` could not parse a leading minus.** `xor rax, -1` is how a
  minimal-instruction-set compiler writes `not`, so this stopped the bitwise
  demo dead. Negative immediates now parse, and `golden4` covers them.

**On the compiler side:**

- `--nasm`: `section`/`global` instead of `.section`/`.globl`, `db` instead of
  `.string` and `.zero`, no `offset`, no `ptr` size keywords.
- String literals are **pooled and emitted after the last function**. In GNU-as
  mode `gen_string` switches to `.rodata`, emits the bytes inline and switches
  back. With one flat segment there is no `.rodata` to switch to, so those bytes
  would have sat in the instruction stream and been executed.
- `dil`, `sil` and `r8b`..`r15b` need a REX prefix to name at all, and the
  minimal target only has the four REX-free byte registers. A `char` parameter
  now goes through `rax` on the way to its stack slot.

### 8.2 Still true

The assembler cannot yet assemble its own source. See section 9 for exactly
what stands in the way — it is a much smaller list than it looked.

---

## 9. Self-host readiness: the measured gap

    make selfhost-scan

`tools/selfhost_scan.py` walks a NASM-subset source and reports **every**
construct outside the assembler's own accepted subset, so the whole gap is
visible at once instead of one `unknown mnemonic` abort at a time.

Against `fixed/selfContained.asm` it reports **168 sites**:

| Sites | Construct | Rewrite inside the existing subset |
|------:|-----------|------------------------------------|
| 49 | `eax` (and 1 `edi`) | needs a **dword operand size** |
| 41 | `inc` | `add reg, 1` |
| 25 | `movzx r64, byte [m]` | `mov al, [m]` + `and rax, 255` |
| 18 | `test r, r` | `cmp r, 0` |
| 9 | `ax` | needs a **word operand size** |
| 7 | `lea r, [sym]` | `mov r, sym` — a bare symbol already assembles as its address |
| 4 | `push` | `sub rsp, 8` + `mov [rsp], r` |
| 4 | `pop` | `mov r, [rsp]` + `add rsp, 8` |
| 3 | `[rdi + rcx]` (SIB) | `add rdi, rcx` then `[rdi]` |
| 3 | `imul r, const` | shift-add |
| 1 | `mul rcx` | shift-add |
| 1 | `rep movsb` | explicit loop |
| 1 | `dec` | `sub reg, 1` |
| 1 | `dil` | route through `al` |

*(It was 156 before the `dw`/`dd`/`dq` work in section 10 — that added code,
and the new code is written in the same style as the rest of the file. The
count is a measurement, not a target; it will keep moving until the rewrite
is done deliberately.)*

Two things follow from this.

**Every directive the source uses is already implemented.** `section`,
`global`, `align`, `equ`, `db`/`dw`/`dd`/`dq` and `resb`/`resq` all assemble
today, so none of the gap is directive work.

**Only two of the fourteen rows need the assembler changed at all** — the 56
`eax`/`ax` sites. Those are not new *instructions*; they are new operand
*sizes*, and the operand slots already carry a size field (`opA + 32`) that
today holds only 8 or 64. Extending it to 16 and 32 is a `0x66` prefix and
dropping `REX.W`, which keeps the instruction set exactly as small as it is
now. The remaining 100 sites are mechanical rewrites of the assembler's own
source, changing no encoding logic whatsoever.

The rewrites in the right-hand column are not theoretical — `tests/` includes
a program built entirely from them (bare symbol as immediate, `add` for `inc`,
`cmp r, 0` for `test`, manual `rsp` arithmetic for `push`/`pop`) which
assembles and runs correctly under the assembler as it stands today.

### 9.1 A separate question: building the *compiler* without gcc

Assembling `nano_cc`'s **output** works today for every demo. Building
`nano_cc` **itself** without gcc is a different problem, and the blockers are
in the compiler, not the assembler. `nano_cc` currently rejects its own source:

| Construct | Uses in `simpleC++.c` | Status |
|-----------|----------------------:|--------|
| `typedef` | 9 | `error: type expected` |
| `enum` | 3 | `error: type expected` |
| brace initialisers | 7 | `error: expression expected` |
| `unsigned` | 21 | **parses and is silently ignored** |
| libc (`malloc`, `fopen`, `printf`, `strcmp`, …) | 19 distinct functions across 5 `#include`s | needs a freestanding replacement |

The `unsigned` row is the dangerous one: it is accepted rather than rejected,
so a self-compiled build would differ from a gcc-built one only in the
arithmetic, and only sometimes.

---

## 10. Data directives: `dw`, `dd`, `dq`

Added so the compiler can emit a pointer inside a global initialiser
(`char *r[3] = {"a","b","c"}` becomes `dq .LD0` / `dq .LD1` / `dq .LD2`).

Two bugs surfaced doing it, both silent:

**`dw`/`dd`/`dq` were in the "recognised and ignored" table.** `pp: dq msg`
emitted **nothing** and did not advance the program counter, so `pp` silently
aliased whatever label came next and every address after it was wrong. No
error, no warning — the program just read the wrong memory. They are real
directives now, handled by `parse_data`, and removed from `directive_table`.

**`[label + N]` dropped the displacement.** `parse_operand` stored the symbol
address and jumped straight to `.close`, skipping the code that parses `+ N`,
so `[nums + 8]` assembled as `[nums]`. It produced a working binary that read
the wrong field — a one-byte difference in the encoding, which is exactly the
class of bug only the byte comparison against GNU as catches. `golden5.asm`
now covers it.

A forward reference in a data directive (`pp: dq msg` with `msg` defined
further down) is normal, so an unknown symbol is a placeholder during the
sizing pass and an error only during the emit pass.
