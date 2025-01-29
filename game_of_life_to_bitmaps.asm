; Conway's Game of Life
; By Matt Johnson (https://github.com/mjohnson108)
; See https://en.wikipedia.org/wiki/Conway%27s_Game_of_Life
; nasm -g -f elf64 game_of_life_to_bitmaps.asm
; ld -o game_of_life_to_bitmaps game_of_life_to_bitmaps.o
; in usage takes .cells file and number of ticks to run for, and produces bitmaps in the working directory for output. e.g.:-
; ./game_of_life_to_bitmaps 232p7h3v0puffer.cells 50 
; Some pattern files can be found here: https://conwaylife.com/patterns/

section .data

	; various error messages
	usage_str		    db	    'Please enter pattern filename (.cells format) and number of iterations', 0x0a
	usage_len		    equ	    $-usage_str

	mmap_error_str		db	    'mmap failed.', 0x0a
	mmap_error_len		equ	    $-mmap_error_str

	file_error_str		db	    'Error writing to output file.', 0x0a
	file_error_len		equ	    $-file_error_str

	number_error_str	db	    'Error in number of iterations.', 0x0a
	number_error_len	equ	    $-number_error_str

	FNF_error_str       db      'File not found.', 0x0a
	FNF_error_len    	equ     $-FNF_error_str

	denied_error_str    db      'Permission denied.', 0x0a
	denied_error_len 	equ     $-denied_error_str

	; Write the board to a bitmap every iteration/'tick'
	; 62 is the total length of the header including the colour table
	; the width and height are calculated based on the specified input file
	; BMP header
	BMP_ident:		    db	'BM'
	BMP_file_size:		dd	0	    ;62+(row_length*total_rows)
	BMP_res1:		    dw	0
	BMP_res2:		    dw	0
	BMP_img_offset:		dd	62
	; DIB header
	BMP_header_size:	dd	40		
	BMP_width:		    dd	0 	    ; row_length
	BMP_height:		    dd	0 	    ; total_rows
	BMP_planes:		    dw	1
	BMP_bpp:		    dw	8	
	BMP_compression:	dd	0
	BMP_img_size:		dd	0	    ; row_length*total_rows 
	BMP_x_res:		    dd	2835
	BMP_y_res:		    dd	2835
	BMP_num_cols:		dd	2		; number of colours in the colour table	
	BMP_imp_cols:		dd	0
	; Colour table. Only two entries as there are only two cell states
	dead_colour:		db	0xff, 0xff, 0xff, 0xff	; white
	live_colour:		db	0x00, 0x00, 0x00, 0x00	; black

	out_file:		    db	'GoL_'	
	file_num:		    db	'00000000'	; this will be overwritten according to the tick number
	file_num_len		equ	$-file_num
	file_ext:		    db	'.bmp', 0x00
	
    ; ticks
	iteration		    dq	1
	num_iterations		dq	0

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

	; buffers for simulation
	buffer_ptr		    resq	1
	row_length		    resq	1
	total_rows		    resq	1
	buffer_size		    resq	1
	src_ptr			    resq	1
	dst_ptr			    resq	1

section .text

global _start

_start:

	; process input parameters
	pop rax			
	cmp rax, 3 
	jne usage

	pop rsi				    ; skip past program name

	; get pointers to the strings entered for input pattern and number of ticks
	pop rsi				    ; filename
	mov [pattern_file_ptr], rsi
	pop rsi				    ; ticks
	mov [ticks_ptr], rsi

	; convert ticks passed into the program, into a number
	mov rsi, [ticks_ptr]
	call string_to_num
	mov [num_iterations], rcx
	
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
	; the file and read the file again to get the actual board 
    ; data into the allocated memory.
	; This file loader makes a lot of assumptions about the 
	; format of the input file (e.g. the comment (!) char is at 
    ; the beginning of a line) but it seems to work so far

	mov [PT_file_desc], rax    	; file descriptor
	mov r9, 0			        ; state. Start in state=0
	mov r10, 0			        ; columns
	mov r11, 0			        ; rows
	mov r12, 0			        ; temp for current row column counter
	mov r13, 0			        ; offset into file where the board data begins

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
	cmp r9, 0		            ; state 0 is a kind of holding state
	je PT_state_0
	cmp r9, 1		            ; state 1 means reading a comment
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
	inc r12			            ; keep track of the number of columns
	jmp PT_read_loop
PT_state_2_0:
	inc r11			            ; increment row counter
	mov r9, 0		            ; reset state
	cmp r12, r10		        ; keep track of the maximum row length in r10
	cmova r10, r12		        ; since .cells files can have a variable row length
	mov r12, 0
	jmp PT_read_loop
PT_state_0: 
	; check to see if it's the start of a comment
	cmp byte [PT_char_buf], '!'	; start of a comment
	je PT_state_0_0
	mov r9, 2			        ; assume we've entered a cell data row, set state=2
	jmp PT_state_2			    ; process the data cell just read
PT_state_0_0:
	mov r9, 1			        ; set state=1, 'reading comment' state
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
	mov rax, 9			        ; mmap is syscall 9
	mov rdi, 0 			        ; let the kernel choose where the memory starts
	mov esi, [pattern_size]		; the size in bytes that we want
	mov rdx, 3 			        ; memory protection: PROT_READ | PROT_WRITE
	mov r10, 34 			    ; flags: MAP_PRIVATE | MAP_ANONYMOUS
	mov r8, -1 			        ; no file descriptor
	mov r9, 0 			        ; no offset
	syscall	

	cmp rax, -1			        ; if returns -1 then map failed. Otherwise contains the starting address of the memory we wanted
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
	; determine size of final buffers for simulation,
	; and setup bitmap header
	; Make the simulation buffer twice the dimension of the pattern read in.
	; This is a bit arbitrary, would perhaps be better to ask the user for the board dimensions

	mov rax, [pattern_cols]
	sal rax, 1			        ; buffer is double the initial pattern width
	and al, 11111100b		    ; ensure a multiple of 4 for bitmap
	mov [row_length], rax
	mov [BMP_width], eax

	mov rbx, [pattern_rows]
	sal rbx, 1			        ; buffer is double the height of the initial pattern
	mov [total_rows], rbx
	mov [BMP_height], ebx

	mul rbx				        ; compute the total size, rows*cols
	mov [buffer_size], rax
	mov [BMP_img_size], eax
	mov rsi, rax			
	add rax, 62			        ; BMP file size including header
	mov [BMP_file_size], eax

	; allocate memory for the simulation buffers
	; 2 * row_length * total_rows
	mov rax, 9			        ; mmap is syscall 9
	mov rdi, 0 			        ; let the kernel choose where the memory starts
	;mov esi, buffer_size 		; rsi is already set above
	sal rsi, 1			        ; double it, as we want two buffers
	mov rdx, 3 			        ; memory protection: PROT_READ | PROT_WRITE
	mov r10, 34 			    ; flags: MAP_PRIVATE | MAP_ANONYMOUS
	mov r8, -1 			        ; no file descriptor
	mov r9, 0 			        ; no offset
	syscall	

	cmp rax, -1			        ; if returns -1 then map failed. Otherwise contains the starting address of the memory we wanted
	je mmap_failed
	mov [buffer_ptr], rax		; save address

	; zero the buffers
	mov rdi, [buffer_ptr]
	mov rax, 0x00
	mov rcx, [buffer_size]
	sal rcx, 1
	rep stosb

	; initialize the buffer pointers
	mov rax, [buffer_ptr]
	mov [src_ptr], rax
	add rax, [buffer_size]
	mov [dst_ptr], rax

	; initialize the source buffer with the pattern from the .cells file 
	; bitmaps are flipped vertically in the file format. So to get the pattern to look the
	; right way up, it is written from the bottom of the buffer to the top.
	; try to put the pattern in the middle of the allocated buffer
	; compute horizontal offset
	mov r8, [row_length]
	sub r8, [pattern_cols]
	sar r8, 1

	; compute vertical offset
	mov r9, [total_rows]
	sub r9, [pattern_rows]
	sar r9, 1
	mov rax, [total_rows]			
	sub rax, r9
	mul qword [row_length]			; convert from row offset to byte offset

	mov rsi, [pattern_ptr] 			; the source pattern
	mov rbx, [src_ptr]			    ; write it to the first buffer
	add rbx, rax				    ; add vertical offset		
	mov rdx, [pattern_rows]			; the number of rows in the pattern

pattern_init_loop:		
	mov rdi, rbx			 
	add rdi, r8				        ; add horizontal offset each row
	mov rcx, [pattern_cols]
	rep movsb				        ; copy a row
	sub rbx, [row_length]			; move 'up' a row
	dec rdx					        ; row counter
	jnz pattern_init_loop

	; run the pattern with the Game of Life rules

life_loop:
	; 'snapshot' the source buffer to a .bmp file
	mov rsi, [src_ptr]
	call snapshot_buffer

	mov rdi, [dst_ptr]	    ; rdi points to output buffer

	; there is a 1 cell border around the whole board which does not get processed.
	; (it is forced to be dead cells). The board is supposed to be infinite but can't
	; do that in this memory representation.
	; move rsi and rdi past the first row in the buffers.
	; use r10 and r11 as pointers as well for previous and next row of cells
	; this is to save having to compute offsets all the time from rsi
	mov r10, rsi		    ; r10 = previous row (cell above)
	add rsi, [row_length]	; rsi = current row (current cell)
	mov r11, rsi		
	add r11, [row_length]	; r11 = next row (cell below)

	add rdi, [row_length]	; rdi is destination cell.
	mov rdx, [total_rows]	; total number of rows to do
	sub rdx, 2		        ; not processing first and last row
    
next_row_loop:

	; move past first pixel of the row (dead cell border).
	inc rsi
	inc r10
	inc r11
	inc rdi
    
	mov rcx, [row_length]
	sub rcx, 2		        ; not processing last cell of the row

in_row_loop:

	; for each cell
	; sum up alive neighbours according to source buffer
	mov bx, 0
	add bl, [r10 - 1]  	    ; top left corner cell
	add bl, [r10]      	    ; top middle cell
	add bl, [r10 + 1]  	    ; top right corner cell
	add bl, [rsi - 1]       ; middle left cell
	add bl, [rsi + 1]       ; middle right cell
	add bl, [r11 - 1]  	    ; bottom left corner cell
	add bl, [r11]      	    ; bottom middle cell
	add bl, [r11 + 1]  	    ; bottom right corner cell
    
	; the number of alive neighbours is in bl
	; if the number of neighbours is 3 then set to 1 in the destination buffer
	cmp bl, 3
	sete [rdi]
	je GOL_continue         ; nothing more to do for this cell, move on
	; if live and there are 2 neighbours then set to 1 in the destination buffer
	; otherwise reset to 0
	cmp byte [rsi], 1
	sete [rdi]
	cmp bl, 2
	sete bh
	and [rdi], bh

GOL_continue:

	inc rsi		; move pointers on to next cell
	inc r10
	inc r11
	inc rdi
    
	dec rcx 	; handle counter
	jnz in_row_loop

	; move pointers past the pixel border at the end of the row
	inc rsi
	inc r10
	inc r11
	inc rdi
    
	; go onto the next row
	dec rdx
	jnz next_row_loop

	; done one tick. 
	; the destination buffer becomes the source and vice versa
	mov r12, [src_ptr]
	xchg r12, [dst_ptr]
	mov [src_ptr], r12

	; increase the iteration counter
	inc qword [iteration]	
	mov r9, [num_iterations]
	cmp qword [iteration], r9	; quit if reached the specified number of ticks to run for
	jle life_loop

exit:

	mov rax, 0x3c
	mov rdi, 0
	syscall

;;;;;;;;;;
; some error messages

usage:
	mov rsi, usage_str
	mov rdx, usage_len
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

file_write_error:
	mov rsi, file_error_str
	mov rdx, file_error_len
	call write_out
	jmp exit

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

;;;;;;;;;

snapshot_buffer:
	; save to bitmap
	; rsi should point to the start of the buffer to write
	push rsi

	; make sure the filename is correct
	call update_filename

	; open the specified file for writing. 
	; Create and truncate the file if necessary and apply some basic permissions
	mov rax, 2
	mov rdi, out_file
	mov rsi, 1101o ; flags: O_TRUNC | O_CREAT | O_WRONLY
	mov rdx, 0664o	; permissions: -rw-rw-r--
	syscall

	cmp rax, -13
	je exit

	mov r8, rax			; file descriptor

	; write out the file
	; header first
	mov rsi, BMP_ident
	mov rdx, 62 
	mov rax, 1
	mov rdi, r8 
	syscall

	; check to make sure the entire header was written
	cmp rax, 62
	jne file_write_error

	; write out the image data
	pop rsi
	mov rdx, [buffer_size]
	mov rax, 1
	mov rdi, r8
	syscall

	; check to make sure all the image data was written
	cmp rax, [buffer_size]
	jne file_write_error

	; close the file
	mov rax, 3
	mov rdi, r8
	syscall

	; done
	ret

update_filename:
	mov rax, [iteration]	; the output bitmap filename is based on the iteration number
	mov r8, 10		    	; we divide repeatedly by 10 to convert number to string
	mov rdi, file_ext		; start from the end and work back
	mov rcx, 0		    	; this will contain the final number of chars
itoa_inner:
	dec rdi			    	; going backwards in memory
	mov rdx, 0		    	; set up the division: rax already set
	div r8			    	; divide by ten
	add rdx, 0x30	    	; offset the remainder of the division to get the required ascii char
	mov [rdi], dl			; write the ascii char to the buffer
	inc rcx			    	; keep track of the number of chars produced
	cmp rcx, file_num_len	; try not to overfeed the buffer
	je itoa_done			; break out if we reach the end of the buffer 
	cmp rax, 0		    	; otherwise keep dividing until nothing left 
	jne itoa_inner
itoa_done:
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
	je done_string			    ; if it's null we're done converting
	imul rcx, 10                ; multiply rcx by ten
	inc rsi                     ; increment pointer to get next char when we loop
	jmp atoi_loop
done_string:
	; rcx is the number
	ret


				
