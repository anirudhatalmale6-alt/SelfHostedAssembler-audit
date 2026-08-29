; bss.asm — reservations: resb, resw, resd, resq.
;
; This program is not byte-compared against GNU as the way the other tests are,
; and the reason is worth stating rather than hiding. `ld` decides where to put
; .bss; mini-asm puts it at a fixed address of its own. Both are correct, the
; immediates therefore differ, and the comparison would fail for a reason that
; has nothing to do with encoding.
;
; What it checks instead is everything a reservation has to be true about:
;
;   1. the label is DEFINED. Before resb was implemented the line was skipped
;      whole, so the name never reached the symbol table and the first
;      reference to it died with an empty "Error:" and nothing else.
;   2. the memory READS BACK AS ZERO. That only happens if p_memsz reaches past
;      p_filesz; if it did not, the page would not be mapped and this faults.
;   3. two reservations are DIFFERENT MEMORY. A resb that defined every label at
;      one address would pass a test that only ever used one of them.
;   4. the widths are honoured: resw, resd and resq reserve 2, 4 and 8 bytes per
;      element, so a run of them lands at known distances apart.
;   5. it is WRITABLE, including one byte at a time.
;
; Nothing is emitted for any of it — that is the whole point, and the caller
; checks the file size as well as the exit code.
;
; Everything here stays inside the assembler's documented subset. In particular
; there is no `mov al, 9` and no `cmp al, 0`: 8-bit immediate forms are not in
; the subset, and today they assemble to something else without complaint.
;
; Exits 42.

global _start

section .text
_start:
    ; --- 2. a fresh reservation reads back as zero ---
    mov rax, [first]
    cmp rax, 0
    jne bad
    mov rax, [last]
    cmp rax, 0
    jne bad

    ; --- 3. writing one does not write the other ---
    mov rax, 11
    mov [first], rax
    mov rax, 31
    mov [last], rax
    mov rax, [first]
    cmp rax, 11
    jne bad

    ; --- 5. one byte at a time, through a pointer ---
    ; xor first, so that a byte load into al leaves a value the 64-bit
    ; compare can read. `mov al, [rsi]` writes 8 bits and leaves the other 56
    ; alone, which is exactly the trap this avoids rather than relies on.
    mov rsi, gap
    xor rax, rax
    mov al, [rsi]
    cmp rax, 0
    jne bad
    mov rax, 9
    mov [rsi], al
    xor rax, rax
    mov al, [rsi]
    cmp rax, 9
    jne bad

    ; --- 4. the widths. words is 4 * 2 bytes, so dwords starts 8 later;
    ;        dwords is 4 * 4, so last starts 16 after that. ---
    mov rax, dwords
    mov rbx, words
    sub rax, rbx
    cmp rax, 8
    jne bad
    mov rax, last
    mov rbx, dwords
    sub rax, rbx
    cmp rax, 16
    jne bad

    ; --- gap really is 4096 bytes wide ---
    mov rax, words
    mov rbx, gap
    sub rax, rbx
    cmp rax, 4096
    jne bad

    ; --- the answer comes out of reserved memory, not out of a register ---
    mov rax, [first]
    mov rbx, [last]
    add rax, rbx           ; 11 + 31
    mov rdi, rax
    mov rax, 60
    syscall

bad:
    mov rdi, 1
    mov rax, 60
    syscall

; The reservations come after the code on purpose. mini-asm emits one flat
; image in source order and the entry point is its first byte, so a `section
; .data` ahead of `section .text` would make the program start executing its
; own data. Reservations are the one thing that can safely sit anywhere,
; because they emit nothing at all — which is the property under test.
section .bss
first  resq 1
gap    resb 4096
words  resw 4          ; 8 bytes
dwords resd 4          ; 16 bytes
last   resq 1
