.section .bss
input_buf:      .space 256
output_buf:     .space 1024
temp_buf:       .space 256
proc_buf:       .space 160
process_count:  .space 4
current_time:   .space 4

# Round Robin helpers (optional)
rr_queue:       .space 64
rr_head:        .space 4
rr_tail:        .space 4

.section .data
newline:        .asciz "\n"

.section .text
.global _start

_start:
    # READ INPUT
    mov     $0, %rax
    mov     $0, %rdi
    lea     input_buf(%rip), %rsi
    mov     $256, %rdx
    syscall



##################################
# EXIT SYSCALL
##################################
.exit:
    mov     $60, %rax
    xor     %rdi, %rdi
    syscall