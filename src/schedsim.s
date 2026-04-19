.section .bss
input_buf:      .space 2048
output_buf:     .space 4096
# struct process: 24 bytes per process
# 0: ID, 4: Burst, 8: Arrival, 12: Priority, 16: Remain, 20: OrigIndex
procs:          .space 240 
algo:           .space 4    # 0=FCFS, 1=SJF, 2=SRTF, 3=PF, 4=RR
num_procs:      .space 4
quantum:        .space 4
rr_q:           .space 4096 # Circular buffer for RR queue (1024 * 4 bytes)

.section .text
.global _start

_start:
    # 1. Read input from stdin
    mov $0, %eax
    mov $0, %edi
    lea input_buf(%rip), %rsi
    mov $2048, %edx
    syscall

    # 2. Skip leading whitespace
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

    # 3. Identify Scheduling Algorithm
parse_algo:
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
    add $4, %rsi
    jmp parse_procs
is_pf:
    movl $3, algo(%rip)
    add $2, %rsi
    jmp parse_procs
is_rr:
    movl $4, algo(%rip)
    add $2, %rsi
    jmp parse_procs
is_s:
    # Check if SJF or SRTF
    movzbl 1(%rsi), %eax
    cmp $'J', %eax
    je is_sjf
    movl $2, algo(%rip)  # SRTF
    add $4, %rsi
    jmp parse_procs
is_sjf:
    movl $1, algo(%rip)
    add $3, %rsi

    # 4. Parse Processes
parse_procs:
    xor %r12, %r12          # r12 = process count (num_procs)
    lea procs(%rip), %r13   # Pointer to current process struct
parse_loop:
    movzbl (%rsi), %eax
    cmp $0, %eax
    je parse_done
    cmp $10, %eax           # Newline
    je parse_done
    cmp $13, %eax           # Carriage return
    je skip_proc_space
    cmp $32, %eax           # Space
    je skip_proc_space

    # Check if we are reading RR's quantum digit
    movl algo(%rip), %ebx
    cmp $4, %ebx
    jne parse_id
    cmp $'0', %eax
    jl parse_id
    cmp $'9', %eax
    jg parse_id
    # It's the quantum!
    call parse_num
    movl %eax, quantum(%rip)
    jmp parse_done

skip_proc_space:
    inc %rsi
    jmp parse_loop

parse_id:
    # Read ID
    movl %eax, 0(%r13)
    inc %rsi
    inc %rsi                 # Skip '-'

    # Read Burst
    call parse_num
    movl %eax, 4(%r13)
    movl %eax, 16(%r13)      # Remain = Burst
    movl %r12d, 20(%r13)     # Orig = num_procs

    # Default Arrival = 0, Priority = 0
    movl $0, 8(%r13)
    movl $0, 12(%r13)

    # Check if Arrival Time is expected
    movl algo(%rip), %ebx
    cmp $0, %ebx
    je has_arr
    cmp $2, %ebx
    je has_arr
    cmp $3, %ebx
    je has_arr
    jmp proc_done

has_arr:
    inc %rsi                 # Skip '-'
    call parse_num
    movl %eax, 8(%r13)

    # Check if Priority is expected
    movl algo(%rip), %ebx
    cmp $3, %ebx
    jne proc_done
    inc %rsi                 # Skip '-'
    call parse_num
    movl %eax, 12(%r13)

proc_done:
    add $24, %r13
    inc %r12
    jmp parse_loop

parse_num:
    # Parses digits from %rsi into %eax
    xor %eax, %eax
num_loop:
    movzbl (%rsi), %ecx
    cmp $'0', %ecx
    jl num_done
    cmp $'9', %ecx
    jg num_done
    
    # eax = eax * 10
    mov %eax, %edx
    shl $3, %eax
    add %edx, %eax
    add %edx, %eax
    
    sub $'0', %ecx
    add %ecx, %eax
    inc %rsi
    jmp num_loop
num_done:
    ret

parse_done:
    movl %r12d, num_procs(%rip)

    # 5. General Initialization
    xor %r14, %r14           # R14 = current time
    xor %r15, %r15           # R15 = out_len

    # Pre-count processes with 0 burst time
    xor %r12, %r12           # R12d = done_count
    lea procs(%rip), %r8
    movl num_procs(%rip), %ecx
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

    # 6. Main Simulation (FCFS, SJF, SRTF, PF)
simulate_other:
    movl num_procs(%rip), %ebx
    cmp %ebx, %r12d
    je sim_done

    mov $99, %r10d           # best_idx = invalid
    xor %rcx, %rcx           # i = 0
    lea procs(%rip), %r13
find_loop:
    cmp %ebx, %ecx
    je find_done

    movl 16(%r13), %eax      # i.rem
    cmp $0, %eax
    je next_proc             # Skip finished

    movl 8(%r13), %eax       # i.arr
    cmp %r14d, %eax
    jg next_proc             # Skip not yet arrived

    cmp $99, %r10d
    je set_best

    # Address of current best -> r11
    mov %r10, %r11
    imul $24, %r11, %r11
    lea procs(%rip), %r8
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
    movl 8(%r13), %eax       # i.arr
    movl 8(%r11), %edx       # best.arr
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig
cmp_sjf:
    movl 4(%r13), %eax       # i.burst
    movl 4(%r11), %edx       # best.burst
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig
cmp_srtf:
    movl 16(%r13), %eax      # i.rem
    movl 16(%r11), %edx      # best.rem
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig
cmp_pf:
    movl 12(%r13), %eax      # i.pri
    movl 12(%r11), %edx      # best.pri
    cmp %edx, %eax
    jl set_best
    jg next_proc
    # Tie priority -> minimum remain
    movl 16(%r13), %eax
    movl 16(%r11), %edx
    cmp %edx, %eax
    jl set_best
    jg next_proc
    jmp cmp_orig

cmp_orig:
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

    # Extract chosen process structure
    mov %r10, %r11
    imul $24, %r11, %r11
    lea procs(%rip), %r8
    add %r8, %r11

    # Check Preemptive vs Non-Preemptive
    movl algo(%rip), %eax
    cmp $0, %eax
    je sim_np
    cmp $1, %eax
    je sim_np

    # Preemptive ticks (SRTF, PF)
    movl 0(%r11), %eax
    lea output_buf(%rip), %r9
    movb %al, (%r9, %r15, 1)
    inc %r15
    inc %r14d                # time++
    
    movl 16(%r11), %eax
    dec %eax
    movl %eax, 16(%r11)
    cmp $0, %eax
    jne simulate_other
    inc %r12d
    jmp simulate_other

sim_np:
    # Non-Preemptive runs full process (FCFS, SJF)
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
    add %eax, %r14d          # time += rem
    movl $0, 16(%r11)        # rem = 0
    inc %r12d
    jmp simulate_other

sim_idle:
    lea output_buf(%rip), %r9
    movb $'X', (%r9, %r15, 1)
    inc %r15
    inc %r14d
    jmp simulate_other

    # 7. Simulation Round Robin (RR)
simulate_rr:
    xor %rcx, %rcx           # i=0
    xor %r8, %r8             # head=0
    xor %r9, %r9             # tail=0
    movl num_procs(%rip), %eax
    lea rr_q(%rip), %r10
    lea procs(%rip), %r11
rr_init_loop:
    cmp %eax, %ecx
    je rr_loop
    movl 16(%r11), %ebx
    cmp $0, %ebx
    je rr_skip_enq           # Skip initially completed processes
    movl %ecx, (%r10, %r9, 4)
    inc %r9
    and $1023, %r9
rr_skip_enq:
    inc %rcx
    add $24, %r11
    jmp rr_init_loop

rr_loop:
    movl num_procs(%rip), %eax
    cmp %eax, %r12d
    je sim_done

    cmp %r8, %r9             # head == tail?
    jne rr_pop
    
    # Empty Queue -> Idle
    lea output_buf(%rip), %r11
    movb $'X', (%r11, %r15, 1)
    inc %r15
    inc %r14d
    jmp rr_loop

rr_pop:
    movl (%r10, %r8, 4), %edi # pop idx
    inc %r8
    and $1023, %r8

    mov %rdi, %r11
    imul $24, %r11, %r11
    lea procs(%rip), %r13
    add %r13, %r11           # r11 points to current process

    movl 16(%r11), %ecx      # rem
    movl quantum(%rip), %edx # q
    cmp %edx, %ecx
    jge use_q
    mov %ecx, %ebx           # run_time = rem
    jmp rr_out
use_q:
    mov %edx, %ebx           # run_time = q

rr_out:
    movl 0(%r11), %eax       # process id
    lea output_buf(%rip), %rsi
    mov %ebx, %ecx           # run_time
rr_out_loop:
    cmp $0, %ecx
    je rr_pad
    movb %al, (%rsi, %r15, 1)
    inc %r15
    dec %ecx
    jmp rr_out_loop

rr_pad:
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
    movl %eax, 16(%r11)      # rem -= run_time
    movl quantum(%rip), %ecx
    add %ecx, %r14d          # time += q
    cmp $0, %eax
    jle rr_proc_done
    
    # Push back
    movl %edi, (%r10, %r9, 4)
    inc %r9
    and $1023, %r9
    jmp rr_loop
rr_proc_done:
    inc %r12d
    jmp rr_loop

    # 8. Finished Simulation
sim_done:
    lea output_buf(%rip), %rsi
    movb $10, (%rsi, %r15, 1) # Append Newline
    inc %r15

    mov $1, %eax             # sys_write
    mov $1, %edi             # stdout
    mov %r15, %rdx
    syscall

.exit:
    mov $60, %eax            # sys_exit
    xor %edi, %edi
    syscall