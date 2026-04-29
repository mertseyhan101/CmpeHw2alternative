# We store each process as a 24-byte block (struct) in proc_buf.
# Layout: [0] ID, [4] Burst, [8] Arrival, [12] Priority, [16] Remaining, [20] OriginalIndex

.section .bss
input_buf:      .space 2048
output_buf:     .space 4096
proc_buf:       .space 240      # 10 processes max * 24 bytes each
algo:           .space 4        # 0=FCFS, 1=SJF, 2=SRTF, 3=PF, 4=RR
process_count:  .space 4
quantum:        .space 4
rr_q:           .space 4096     # RR queue holds up to 1024 process indices (4 bytes each)

.section .text
.global _start

_start:
    # Read the entire input line at once so we can parse it freely afterward.
    mov $0, %rax
    mov $0, %rdi
    lea input_buf(%rip), %rsi
    mov $2048, %rdx
    syscall

    # Skip any leading whitespace before the algorithm name.
    lea input_buf(%rip), %rsi
skip_space:
    movzbl (%rsi), %eax
    cmp $32, %eax
    je skip_sp
    cmp $10, %eax
    je skip_sp
    cmp $13, %eax
    je skip_sp
    jmp parse_algo
skip_sp:
    inc %rsi
    jmp skip_space

parse_algo:
    # We identify the algorithm by its first character, then skip past its name.
    # For 'S' we also check the second character to distinguish SJF from SRTF.
    movzbl (%rsi), %eax
    cmp $'F', %eax
    je is_fcfs
    cmp $'S', %eax
    je is_s
    cmp $'P', %eax
    je is_pf
    cmp $'R', %eax
    je is_rr

is_fcfs:
    movl $0, algo(%rip)
    add $4, %rsi            # skip "FCFS"
    jmp parse_procs
is_pf:
    movl $3, algo(%rip)
    add $2, %rsi            # skip "PF"
    jmp parse_procs
is_rr:
    movl $4, algo(%rip)
    add $2, %rsi            # skip "RR"
    jmp parse_procs
is_s:
    movzbl 1(%rsi), %eax
    cmp $'J', %eax
    je is_sjf
    movl $2, algo(%rip)     # second letter is not J, so it must be SRTF
    add $4, %rsi
    jmp parse_procs
is_sjf:
    movl $1, algo(%rip)
    add $3, %rsi            # skip "SJF"

parse_procs:
    xor %r12, %r12
    lea proc_buf(%rip), %r13
parse_loop:
    movzbl (%rsi), %eax
    cmp $0, %eax
    je parse_done
    cmp $10, %eax
    je parse_done
    cmp $13, %eax
    je skip_proc_space
    cmp $32, %eax
    je skip_proc_space

    # For RR, the last token is a digit (quantum), not a process descriptor.
    # We detect this by checking if we are in RR mode and the current char is a digit.
    movl algo(%rip), %ebx
    cmp $4, %ebx
    jne parse_id
    cmp $'0', %eax
    jl parse_id
    cmp $'9', %eax
    jg parse_id
    call parse_num
    movl %eax, quantum(%rip)
    jmp parse_done

skip_proc_space:
    inc %rsi
    jmp parse_loop

parse_id:
    movl %eax, 0(%r13)
    inc %rsi
    inc %rsi                # skip the '-' after ID

    call parse_num
    movl %eax, 4(%r13)
    movl %eax, 16(%r13)     # remaining time starts equal to burst time
    movl %r12d, 20(%r13)    # save input order for tie-breaking

    movl $0, 8(%r13)        # default arrival = 0
    movl $0, 12(%r13)       # default priority = 0

    # FCFS, SRTF and PF have arrival times; SJF and RR do not.
    movl algo(%rip), %ebx
    cmp $0, %ebx
    je has_arr
    cmp $2, %ebx
    je has_arr
    cmp $3, %ebx
    je has_arr
    jmp proc_done

has_arr:
    inc %rsi
    call parse_num
    movl %eax, 8(%r13)

    # Only PF has a priority field after arrival time.
    movl algo(%rip), %ebx
    cmp $3, %ebx
    jne proc_done
    inc %rsi
    call parse_num
    movl %eax, 12(%r13)

proc_done:
    add $24, %r13
    inc %r12
    jmp parse_loop

parse_num:
    # Reads consecutive digit characters from %rsi and returns the integer in %eax.
    xor %eax, %eax
num_loop:
    movzbl (%rsi), %ecx
    cmp $'0', %ecx
    jl num_done
    cmp $'9', %ecx
    jg num_done
    imul $10, %eax
    sub $'0', %ecx
    add %ecx, %eax
    inc %rsi
    jmp num_loop
num_done:
    ret

parse_done:
    movl %r12d, process_count(%rip)

    xor %r14, %r14          # r14 = current clock time
    xor %r15, %r15          # r15 = number of characters written to output

    # We pre-count processes with burst=0 so the main loop knows when everyone is done.
    xor %r12, %r12
    lea proc_buf(%rip), %r8
    movl process_count(%rip), %ecx
    xor %eax, %eax
check_zero_loop:
    cmp %ecx, %eax
    je sim_start
    movl 16(%r8), %ebx
    cmp $0, %ebx
    jne not_zero
    inc %r12d
not_zero:
    inc %eax
    add $24, %r8
    jmp check_zero_loop

sim_start:
    movl algo(%rip), %eax
    cmp $4, %eax
    je simulate_rr

    # --- FCFS / SJF / SRTF / PF ---
    # Each iteration we scan all processes and pick the best candidate
    # according to the active algorithm's selection rule.
simulate_other:
    movl process_count(%rip), %ebx
    cmp %ebx, %r12d
    je sim_done

    mov $99, %r10d          # 99 means no candidate found yet (max processes is 10)
    xor %rcx, %rcx
    lea proc_buf(%rip), %r13
find_loop:
    cmp %ebx, %ecx
    je find_done

    movl 16(%r13), %eax
    cmp $0, %eax
    je next_proc            # already finished, skip

    movl 8(%r13), %eax
    cmp %r14d, %eax
    jg next_proc            # not arrived yet, skip

    cmp $99, %r10d
    je set_best             # no candidate yet, take the first available

    # Compare current process against the best candidate found so far.
    mov %r10, %r11
    imul $24, %r11
    lea proc_buf(%rip), %r8
    add %r8, %r11

    movl algo(%rip), %eax
    cmp $0, %eax
    je cmp_fcfs
    cmp $1, %eax
    je cmp_sjf
    cmp $2, %eax
    je cmp_srtf
    cmp $3, %eax
    je cmp_pf

cmp_fcfs:
    # FCFS: pick the process that arrived earliest.
    movl 8(%r13), %eax
    movl 8(%r11), %edx
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig
cmp_sjf:
    # SJF: pick the process with the shortest total burst time.
    movl 4(%r13), %eax
    movl 4(%r11), %edx
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig
cmp_srtf:
    # SRTF: pick the process with the least remaining time.
    movl 16(%r13), %eax
    movl 16(%r11), %edx
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig
cmp_pf:
    # PF: pick the process with the lowest priority number (= highest priority).
    # On a tie in priority, we prefer the one with less remaining time (SRTF behavior).
    movl 12(%r13), %eax
    movl 12(%r11), %edx
    cmp %edx, %eax
    jl set_best
    jg next_proc
    movl 16(%r13), %eax
    movl 16(%r11), %edx
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig

cmp_orig:
    # Final tie-breaker: whichever process appeared first in the input wins.
    movl 20(%r13), %eax
    movl 20(%r11), %edx
    cmp %edx, %eax
    jl set_best
    jmp next_proc

set_best:
    mov %ecx, %r10d
next_proc:
    inc %rcx
    add $24, %r13
    jmp find_loop

find_done:
    cmp $99, %r10d
    je sim_idle

    mov %r10, %r11
    imul $24, %r11
    lea proc_buf(%rip), %r8
    add %r8, %r11

    # FCFS and SJF are non-preemptive: once selected, the process runs to completion.
    # SRTF and PF are preemptive: we tick one cycle at a time so a new arrival can preempt.
    movl algo(%rip), %eax
    cmp $0, %eax
    je sim_np
    cmp $1, %eax
    je sim_np

    # Preemptive: output one cycle and decrement remaining time.
    movl 0(%r11), %eax
    lea output_buf(%rip), %r9
    movb %al, (%r9, %r15, 1)
    inc %r15
    inc %r14d
    movl 16(%r11), %eax
    dec %eax
    movl %eax, 16(%r11)
    cmp $0, %eax
    jne simulate_other
    inc %r12d
    jmp simulate_other

sim_np:
    # Non-preemptive: write the process ID for every remaining cycle in one go.
    movl 16(%r11), %ecx
    movl 0(%r11), %eax
    lea output_buf(%rip), %r9
np_loop:
    cmp $0, %ecx
    je np_done
    movb %al, (%r9, %r15, 1)
    inc %r15
    dec %ecx
    jmp np_loop
np_done:
    movl 16(%r11), %eax
    add %eax, %r14d
    movl $0, 16(%r11)
    inc %r12d
    jmp simulate_other

sim_idle:
    # No process is ready this cycle, so we output 'X' and advance the clock.
    lea output_buf(%rip), %r9
    movb $'X', (%r9, %r15, 1)
    inc %r15
    inc %r14d
    jmp simulate_other

    # --- Round Robin ---
    # We use a circular queue (array + head/tail indices) to keep the process order.
    # r8 = head, r9 = tail, r10 = base address of the queue array.
simulate_rr:
    xor %rcx, %rcx
    xor %r8, %r8
    xor %r9, %r9
    movl process_count(%rip), %eax
    lea rr_q(%rip), %r10
    lea proc_buf(%rip), %r11
rr_init_loop:
    # Enqueue all processes in input order at time 0 (spec says all arrive at time 0).
    cmp %eax, %ecx
    je rr_loop
    movl 16(%r11), %ebx
    cmp $0, %ebx
    je rr_skip_enq
    movl %ecx, (%r10, %r9, 4)
    inc %r9
    cmp $1024, %r9
    jne rr_skip_enq
    mov $0, %r9
rr_skip_enq:
    inc %rcx
    add $24, %r11
    jmp rr_init_loop

rr_loop:
    movl process_count(%rip), %eax
    cmp %eax, %r12d
    je sim_done

    cmp %r8, %r9
    jne rr_pop

    # Queue is empty but not all processes are done: idle cycle.
    lea output_buf(%rip), %r11
    movb $'X', (%r11, %r15, 1)
    inc %r15
    inc %r14d
    jmp rr_loop

rr_pop:
    movl (%r10, %r8, 4), %edi
    inc %r8
    cmp $1024, %r8
    jne rr_skip_wrap_head
    mov $0, %r8
rr_skip_wrap_head:

    mov %rdi, %r11
    imul $24, %r11
    lea proc_buf(%rip), %r13
    add %r13, %r11

    movl 16(%r11), %ecx     # rem
    movl quantum(%rip), %edx
    cmp %edx, %ecx
    jge use_q
    mov %ecx, %ebx          # process finishes before quantum ends
    jmp rr_out
use_q:
    mov %edx, %ebx          # process uses the full quantum

rr_out:
    movl 0(%r11), %eax
    lea output_buf(%rip), %rsi
    mov %ebx, %ecx
rr_out_loop:
    cmp $0, %ecx
    je rr_pad
    movb %al, (%rsi, %r15, 1)
    inc %r15
    dec %ecx
    jmp rr_out_loop

rr_pad:
    # If the process finished before the quantum expired, we still output 'X'
    # for the unused cycles so every quantum slot has a fixed width in the output.
    movl quantum(%rip), %ecx
    sub %ebx, %ecx
rr_pad_loop:
    cmp $0, %ecx
    je rr_update
    movb $'X', (%rsi, %r15, 1)
    inc %r15
    dec %ecx
    jmp rr_pad_loop

rr_update:
    movl 16(%r11), %eax
    sub %ebx, %eax
    movl %eax, 16(%r11)
    movl quantum(%rip), %ecx
    add %ecx, %r14d
    cmp $0, %eax
    jle rr_proc_done

    # Process still has work left: put it back at the end of the queue.
    movl %edi, (%r10, %r9, 4)
    inc %r9
    cmp $1024, %r9
    jne rr_skip_wrap_tail
    mov $0, %r9
rr_skip_wrap_tail:
    jmp rr_loop
rr_proc_done:
    inc %r12d
    jmp rr_loop

sim_done:
    lea output_buf(%rip), %rsi
    movb $10, (%rsi, %r15, 1)   # append newline at the end of the output
    inc %r15

    mov $1, %rax
    mov $1, %rdi
    mov %r15, %rdx
    syscall

.exit:
    mov     $60, %rax
    xor     %rdi, %rdi
    syscall
