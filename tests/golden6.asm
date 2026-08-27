; golden6.asm — 64-bit immediates.
;
; `mov reg, imm32` sign-extends its 32-bit field to 64 bits, so any immediate
; outside -2^31 .. 2^31-1 has to use the 10-byte REX.W B8+rd io form instead.
; Getting this wrong is silent: the program assembles, links and runs, and
; simply loads a different number than the source asked for.
;
; The short form must still be chosen whenever it fits, because binutils does,
; and this test is a byte comparison against binutils.
;
; Exits 42.

section .text
global _start

_start:
    ; --- values that DO fit in a sign-extended imm32: 7-byte C7 /0 id ---
    mov rax, 0
    mov rbx, 1
    mov rcx, -1
    mov rdx, 2147483647             ; the largest that fits
    mov rsi, -2147483648            ; the smallest that fits
    mov rdi, 1000000
    mov r8, -1000000
    mov r9, 0x7fffffff
    mov r10, 0
    mov r11, -2
    mov r12, 255
    mov r13, -255
    mov r14, 65536
    mov r15, -65536

    ; --- values that do NOT: 10-byte REX.W B8+rd io ---
    mov rax, 2147483648             ; one past the imm32 boundary
    mov rbx, -2147483649            ; one below it
    mov rcx, 0x7fffffffffffffff
    mov rdx, 0x8000000000000000
    mov rsi, 0x123456789abcdef
    mov rdi, 0xffffffff             ; positive, needs bit 32 clear -- imm32
                                    ; would sign-extend it to -1
    mov r8, 4294967296
    mov r9, -4294967296
    mov r10, 0x0102030405060708
    mov r11, 0xdeadbeefcafebabe
    mov r12, 1099511627776
    mov r13, -1099511627776
    mov r14, 0x00000000ffffffff
    mov r15, 0xfffffffe00000000

    ; --- the boundary again, this time so the RESULT is checked and not just
    ;     the encoding: a truncating assembler gets -2147483648 here ---
    mov rax, 2147483648
    mov rcx, 2147483648
    cmp rax, rcx
    jne fail
    shr rax, 31                     ; 2147483648 >> 31 == 1
    cmp rax, 1
    jne fail

    mov rbx, 0xffffffff
    shr rbx, 16
    cmp rbx, 65535                  ; would be 65535 either way...
    jne fail
    mov rbx, 0xffffffff
    shr rbx, 32                     ; ...but this is 0 only if bit 32 is clear
    cmp rbx, 0
    jne fail

    mov rdx, 0x0102030405060708
    shr rdx, 56
    cmp rdx, 1
    jne fail

    mov rdi, 42
    mov rax, 60
    syscall

fail:
    mov rdi, 1
    mov rax, 60
    syscall
