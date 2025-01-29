; Game of Life in a terminal
; By Matt Johnson (https://github.com/mjohnson108)
; See https://en.wikipedia.org/wiki/Conway%27s_Game_of_Life
; nasm -f elf64 game_of_life_to_terminal.asm
; ld -o game_of_life_to_terminal game_of_life_to_terminal.o
; Open the specified pattern in a .cells file and run 
; it in the terminal for a specified number of ticks
; e.g.:- ./game_of_life_to_terminal ./106p135.cells 100
; Some pattern files can be found here: https://conwaylife.com/patterns/

section .data
	
	; terminal sizes can vary greatly. These might need adjusting for other terminals.
	row_length      	equ     130	
	total_rows		    equ   	50 

	; ANSI sequence to clear and reset the terminal
	cls_code		    db	    0x1b, '[2J', 0x1b, '[H'
	cls_len			    equ	    $-cls_code

	; various error messages
	usage_str		    db	    'Please enter pattern filename (.cells format) and number of iterations', 0x0a
	usage_len		    equ	    $-usage_str

	mmap_error_str		db	    'mmap failed.', 0x0a
	mmap_error_len		equ	    $-mmap_error_str

	FNF_error_str       db      'File not found.', 0x0a
	FNF_error_len    	equ     $-FNF_error_str

	denied_error_str    db      'Permission denied.', 0x0a
	denied_error_len 	equ     $-denied_error_str

	number_error_str	db	    'Error in number of iterations.', 0x0a
	number_error_len	equ	    $-number_error_str

	size_error_str		db	    'Pattern is too big.', 0x0a
	size_error_len		equ	    $-size_error_str

	; for display in the terminal, a dead cell becomes a space 
	; and a live cell a O 
	conversion_table	db	    ' ', 'O'
	
	iteration		    dq	    1
	num_iterations		dq	    0	

	; for nanosleep
	; struct timespec
	tv_sec			    dq	    0
	tv_nsec			    dq	    250000000	; 0.25 seconds in nanoseconds

section .bss

	; pointers to passed parameters
	pattern_file_ptr	resq	1
	ticks_ptr		    resq	1

	; for reading in the pattern (.cells) file
	PT_file_desc		resq	1
	PT_char_buf		    resb	1

	pattern_start		resq	1
	pattern_cols		resq	1
	pattern_rows		resq	1
	pattern_size		resq	1
	pattern_ptr		    resq	1

	buffer_1		    resb	row_length*total_rows
	buffer_2		    resb	row_length*total_rows
	buffer_3		    resb	row_length*total_rows

	src_ptr			    resq	1
	dst_ptr			    resq	1

section .text

global _start

_start:

	; process input parameters
	pop rax			
	cmp rax, 3 
	jne usage

	pop rsi				; skip past program name

	; get pointers to the strings entered for input pattern and number of ticks
	pop rsi				; filename
	mov [pattern_file_ptr], rsi
	pop rsi				; ticks
	mov [ticks_ptr], rsi

	; convert ticks passed into the program, into a number
	mov rsi, [ticks_ptr]
	call string_to_num
	mov [num_iterations], rcx
	
	; read in the pattern
	call read_pattern

	; check to make sure the pattern isn't too big for the terminal
	cmp qword [pattern_cols], row_length
	jge size_error
	cmp qword [pattern_rows], total_rows
	jge size_error

	; zero and set up the buffers
	mov rdi, buffer_1
	mov rax, 0
	mov rcx, 3*row_length*total_rows
	rep stosb

	mov qword [src_ptr], buffer_1
	mov qword [dst_ptr], buffer_2

	; initialize the source buffer with the pattern
	; try to center the pattern in the terminal
	; calculate horizontal offset
	mov r8, row_length
	sub r8, [pattern_cols]
	sar r8, 1

	; calcuate vertical offset
	mov rax, total_rows
	sub rax, [pattern_rows]
	sar rax, 1
	mov r9, row_length
	mul r9

	mov rsi, [pattern_ptr] 			; the source pattern
	mov rbx, [src_ptr]			    ; write it to the first buffer
	add rbx, rax				    ; space at the top
	mov rdx, [pattern_rows]			; the number of rows in the pattern

pattern_init_loop:				    ; use rbx to index into a row to keep rdi clean
	mov rdi, rbx			 
	add rdi, r8				        ; horizontal offset
	mov rcx, [pattern_cols]
	rep movsb
	add rbx, row_length		
	dec rdx					        ; next row
	jnz pattern_init_loop

	; run the pattern with the Game of Life rules
life_loop:
	; 'snapshot' the source buffer to terminal 
	mov rsi, [src_ptr]
	call snapshot_buffer

	mov rdi, [dst_ptr]	            ; rdi points to output buffer
	mov rax, row_length	            ; use rax is index into buffer; here we skip first row
	mov rdx, total_rows	            ; total number of rows to do
	sub rdx, 2		                ; not doing first and last row
    
next_row_loop:

	; move past first pixel of the row.
	; there is a 1 pixel border around the whole frame which does not get processed
	inc rax		
    
	mov rcx, row_length
	sub rcx, 2

in_row_loop:

	; for each cell
	; sum up alive neighbours according to source buffer
	mov bx, 0
	add bl, [rsi + rax - row_length - 1]  ; top left corner cell
	add bl, [rsi + rax - row_length]      ; top middle cell
	add bl, [rsi + rax - row_length + 1]  ; top right corner cell
	add bl, [rsi + rax - 1]               ; middle left cell
	add bl, [rsi + rax + 1]               ; middle right cell
	add bl, [rsi + rax + row_length - 1]  ; bottom left corner cell
	add bl, [rsi + rax + row_length]      ; bottom middle cell
	add bl, [rsi + rax + row_length + 1]  ; bottom right corner cell
    
	; the number of alive neighbours is in bl
	; if the number of neighbours is 3 then set to 1 in the destination buffer
	cmp bl, 3
	sete [rdi + rax]
	je GOL_continue   ; nothing more to do for this cell, move on
	; if live and there are 2 neighbours then set to 1 in the destination buffer
	; otherwise reset to 0
	cmp byte [rsi + rax], 1
	sete [rdi + rax]
	cmp bl, 2
	sete bh
	and [rdi + rax], bh

GOL_continue:

	inc rax ; next cell along
    
	dec rcx ; handle counter
	jnz in_row_loop

	; move past the pixel border at the end of the row
	inc rax
    
	; go onto the next row
	dec rdx
	jnz next_row_loop

	; done one tick. 
	; the destination buffer becomes the source and vice versa
	mov [src_ptr], rdi
	mov [dst_ptr], rsi

	inc qword [iteration]		; increase the iteration counter and loop for next frame
	mov r9, [num_iterations]	
	cmp qword [iteration], r9
	jle life_loop

	; finished
exit:

	mov rax, 0x3c
	mov rdi, 0
	syscall

;;;;;;;;;
; some messages

usage:
	mov rsi, usage_str
	mov rdx, usage_len
	call write_out
	jmp exit

size_error:
	mov rsi, size_error_str
	mov rdx, size_error_len
	call write_out
	jmp exit

mmap_failed:
	mov rsi, mmap_error_str
	mov rdx, mmap_error_len
	call write_out
	jmp exit

fnf_error:

	mov rsi, FNF_error_str
	mov rdx, FNF_error_len
	jmp write_out

denied_error:

	mov rsi, denied_error_str
	mov rdx, denied_error_len
	jmp write_out

number_error:
	mov rsi, number_error_str
	mov rdx, number_error_len
	call write_out
	jmp exit

write_out:
	mov rax, 1
	mov rdi, 1
	syscall
	ret


;;;;;;;;;;

snapshot_buffer:
	; convert the GoL data in rsi to text for writing out
	; 0 becomes space. 1 becomes O. Last column becomes newline
	push rsi

	mov rdi, buffer_3
	mov rbx, conversion_table
	mov rdx, total_rows
do_row:
	mov rcx, row_length-1
do_cells:
	mov al, [rsi]
	xlatb		        ; perform table lookup to convert the cell state to a char
	mov [rdi], al
	inc rsi
	inc rdi
	dec rcx
	jnz do_cells
	; add a newline character to end of row
	mov byte [rdi], 0x0a
	inc rsi
	inc rdi
	dec rdx
	jnz do_row

	; send out this frame.
	; first clear screen
	mov rax, 1          ; write
	mov rdi, 1          ; to stdout
	mov rsi, cls_code   ; ANSI control sequence
	mov rdx, cls_len    ; number of characters to write
	syscall             ; execute

	; then write out the buffer
	mov rax, 1          ; write
	mov rdi, 1          ; to stdout
	mov rsi, buffer_3   ; stringified GoL board
	mov rdx, row_length*total_rows
	syscall             ; execute

	; use nanosleep to pause for a moment so it doesn't all flash by instantly
	mov rax, 0x23
	mov rdi, tv_sec
	mov rsi, 0
	syscall

	pop rsi
	ret
	

read_pattern:
	; load the .cells file
	mov rdi, [pattern_file_ptr]
	mov rax, 2              ; 'open'
	mov rsi, 0              ; flags: O_RDONLY
	mov rdx, 0              
	syscall

	; check for open errors
	cmp rax, -2             
	je fnf_error            ; error: file not found

	cmp rax, -13
	je denied_error         ; error: permission denied
    
PT_proceed:

	; use a simple state machine to process the .cells file.
	; these files can have comments as well as data.
	; There are two passes through the file. In the first pass,
	; try to determine the dimensions of the board in the file.
	; Use those dimensions to allocate some memory, then rewind
	; the file and read the actual board data into the allocated
	; memory.
	; This file loader makes a lot of assumptions about the 
	; format of the input file (e.g. the ! char is at the 
	; beginning of a line) but it seems to work so far

	mov [PT_file_desc], rax    	; file descriptor
	mov r9, 0			; state. Start in state=0
	mov r10, 0			; columns
	mov r11, 0			; rows
	mov r12, 0			; temp for current row column counter
	mov r13, 0			; offset into file where the board data begins

PT_read_loop:
	push r9				        ; save vars across syscall
	push r10
	push r11
	push r12
	push r13
	xor eax, eax            	; read
	mov rdi, [PT_file_desc]    	; from .cells file
	mov rsi, PT_char_buf		; memory location to read to
	mov rdx, 1			        ; read 1 char from the file
	syscall
	pop r13				        ; restore vars
	pop r12
	pop r11
	pop r10
	pop r9

	cmp rax, 1             		; check for EOF
	jne PT_d1

	; current state determines how to process the char just read
	cmp r9, 0		    ; state 0 is a kind of holding state
	je PT_state_0
	cmp r9, 1		    ; state 1 means reading a comment
	je PT_state_1
	; assume state 2 - reading the cell data block
PT_state_2:
	; check for end of line
	cmp byte [PT_char_buf], 0x0a
	je PT_state_2_0
	; skip past 0x0d if present
	cmp byte [PT_char_buf], 0x0d
	je PT_read_loop
	; assume char_buf has valid cell data
	inc r12			    ; keep track of the number of columns
	jmp PT_read_loop
PT_state_2_0:
	inc r11			    ; increment row counter
	mov r9, 0		    ; reset state
	cmp r12, r10		; keep track of the maximum row length in r10
	cmova r10, r12		; since .cells files can have a variable row length
	mov r12, 0
	jmp PT_read_loop
PT_state_0: 
	; check to see if it's the start of a comment
	cmp byte [PT_char_buf], '!'	; start of a comment
	je PT_state_0_0
	mov r9, 2			; assume we've entered a cell data row, set state=2
	jmp PT_state_2			; process the data cell just read
PT_state_0_0:
	mov r9, 1			; set state=1, 'reading comment' state
	inc r13
	jmp PT_read_loop
PT_state_1:	
	; reading a comment. Just pull in bytes until the newline
	inc r13
	cmp byte [PT_char_buf], 0x0a
	jne PT_read_loop
	mov r9, 0		; reset to state=0
	jmp PT_read_loop
PT_d1:
	; final row might not have a newline at the end.
	; Catch up with any final data cells
	cmp r12, 0	
	je PT_d2
	cmp r12, r10
	cmova r10, r12
	inc r11
PT_d2:
	; at this point, r10 should be the number of data columns, r11 the number of data rows
	; save these
	mov [pattern_cols], r10
	mov [pattern_rows], r11
	mov [pattern_start], r13
	mov rax, r10
	mul r11
	mov [pattern_size], rax

	; now have to allocate memory and read the file again to extract the data
	mov rax, 9			; mmap is syscall 9
	mov rdi, 0 			; let the kernel choose where the memory starts
	mov esi, [pattern_size]		; the size in bytes that we want
	mov rdx, 3 			; memory protection: PROT_READ | PROT_WRITE
	mov r10, 34 			; flags: MAP_PRIVATE | MAP_ANONYMOUS
	mov r8, -1 			; no file descriptor
	mov r9, 0 			; no offset
	syscall	

	cmp rax, -1			; if returns -1 then map failed. Otherwise contains the starting address of the memory we wanted
	je mmap_failed
	mov [pattern_ptr], rax		; save address

	; seek back in the file
	mov rax, 8			        ; sys_lseek
	mov rdi, [PT_file_desc]		; file descriptor
	mov rsi, [pattern_start]	; offset into the file where data begins
	mov rdx, 0			        ; SEEK_SET
	syscall

	; read the pattern data into the buffer just created
	xor ecx, ecx		        ; rcx is index into column
	mov rdi, [pattern_ptr]	    ; pointer to the beginning of the memory buffer
PT_pattern_in:
	push rcx
	push rdi
	xor eax, eax                ; read
	mov rdi, [PT_file_desc]	    ; from .cells file
	mov rsi, PT_char_buf	    ; memory location to read to
	mov rdx, 1		            ; read 1 byte
	syscall
	pop rdi
	pop rcx

	cmp rax, 1		            ; check for end of file
	jne PT_d3

	cmp byte [PT_char_buf], 0x0d	; ignore
	je PT_pattern_in
	
	cmp byte [PT_char_buf], 0x0a	; increase row counter if newline
	jne PT_set_cell

	add rdi, qword [pattern_cols]
	xor ecx, ecx
	jmp PT_pattern_in

PT_set_cell:
	; set the byte in the destination buffer if 'O' or '*' (sometimes used in .cells files apparently)
	cmp byte [PT_char_buf], 'O'
	sete [rdi+rcx]	
	cmp byte [PT_char_buf], '*'
	sete al
	or [rdi+rcx], al

	inc rcx
	jmp PT_pattern_in

PT_d3:
	; file has been read into memory.
	ret


string_to_num:
	mov rcx, 0		            ; rcx will be the final number
atoi_loop:
	movzx rbx, byte [rsi]       ; get the char pointed to by rsi
	cmp rbx, 0x30               ; Check if char is below '0' 
	jl number_error
	cmp rbx, 0x39               ; Check if char is above '9'
	jg number_error
	sub rbx, 0x30               ; adjust to actual number by subtracting ASCII offset to 0
	add rcx, rbx                ; accumulate number in rcx
	movzx rbx, byte [rsi+1]     ; check the next char to see if the string continues
	cmp rbx, 0                  ; string should be null-terminated
	je done_string		        ; if it's null we're done converting
	imul rcx, 10                ; multiply rcx by ten
	inc rsi                     ; increment pointer to get next char when we loop
	jmp atoi_loop
done_string:
	; rcx is the number
	ret
				
