	page	60,132

	title	PrtScFX  - FX-80 monochrome graphics print screen patch

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Written by:	Michael Geary					    ;;
;;		Software Wizards				    ;;
;;		P.O. Box 1479					    ;;
;;		Los Gatos, CA 95031				    ;;
;;		(408) 354-4400					    ;;
;;								    ;;
;; This program is placed in the public domain without restriction. ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; character codes
CR	equ	13
LF	equ	10
ESC	equ	27

; interrupt numbers
PrtSc	equ	05h
video	equ	10h
keyboard equ	16h
time	equ	1Ah

; interrupt vector locations in absolute zero segment
absSeg	segment at 0
	org	PrtSc * 4
PrtScIntOffset	dw	?
PrtScIntSeg	dw	?
	org	500h
statusByte	db	?
absSeg	endS

; screen addresses & stuff
monoSeg     equ     0B000h
graphSeg    equ     0B800h
row25offset equ     24 * 160

monoBigCrs  equ     000Dh
graphBigCrs equ     0007h

monoNrmCrs  equ     0C0Dh
graphNrmCrs equ     0607h

codeSeg segment para public 'code'

	extrn	cgData:byte

theEnd	equ	offset cgData + 4096

	org	100h

printScreen	proc	far

	assume	cs:codeSeg, ds:codeSeg, ss:codeSeg, es:absSeg

	xor	ax, ax
	mov	es, ax

	mov	ax, theEnd + 512
	mov	sp, ax

	mov	ax, PrtScIntOffset
	mov	SaveIntOffset, ax
	mov	ax, PrtScIntSeg
	mov	SaveIntSeg, ax

	mov	PrtScIntOffset, offset doPrint
	push	cs
	pop	PrtScIntSeg

	mov	dx, theEnd
	int	27h


scrSeg		dw	?	; B000 or B800 screen segment
pageNo		db	?	; BIOS's page #

crsPos		dw	?	; user's cursor row & column
crsType 	dw	?	; user's cursor type (size)

bigCrs		dw	?	; our big cursor

saveInt 	label	dword	; holds the "other" PrtSc interrupt vector
SaveIntOffset	dw	?
SaveIntSeg	dw	?

paper216ths	db	?	; paper advance after pass (12/216 or 24/216 ")
dotsPerPass	db	?	; # dot rows covered in a pass (4 or 8)

lastCol 	db	?	; last nonblank char col in this print row

prompt		db	' G = text graphics dump, D = darker grap'
		db	'hics, SPACE = normal dump, Esc = cancel '

save25		dw	80 dup (?)

; PrtSc entry point

doPrint:
	assume	cs:codeSeg, ds:nothing, ss:nothing, es:nothing

	sti
	push	ds
	push	es
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	bp

	xor	dx, dx
	mov	es, dx
	cmp	es:statusByte, 1	; check for PrtSc already in progress
	jne	notBusy
	  jmp	exit
notBusy:
	mov	es:statusByte, 1

	mov	ah, 15
	int	video			; get CRT mode in AL
	mov	pageNo, bh
	mov	dx, monoSeg
	mov	cx, monoBigCrs
	mov	si, monoNrmCrs
	cmp	al, 7			; must be monochrome
	je	newDump
	mov	dx, graphSeg
	xor	bl, bl
	add	dx, bx			; (current page segment)
	mov	cx, graphBigCrs
	mov	si, graphNrmCrs
	and	al, 0FEh
	cmp	al, 2			; or 80 column text mode (2 or 3)
	je	newDump
	  jmp	oldDump
newDump:
	mov	scrSeg, dx
	mov	bigCrs, cx
	mov	crsType, si

	mov	ah, 3
	int	video			; save cursor
	mov	crsPos, dx
	cmp	cx, 0067h		; avoid weird bug - incorrect cursor
	je	weirdCrs		; type of 67h
	mov	crsType, cx
weirdCrs:

	or	ch, 20h
	mov	ah, 1
	int	video			; turn cursor off

	mov	ds, scrSeg
	mov	si, row25offset
	push	cs
	pop	es
	mov	di, offset save25
	mov	cx, 80
	rep movsw			; save row 25

	push	cs
	pop	ds
	mov	si, offset prompt
	mov	es, scrSeg
	mov	di, row25offset
	mov	cx, 80
	mov	ah, 70h 		; reverse video
promptLoop:
	lodsb
	stosw				; display prompt message
	loop	promptLoop

kbdClr: mov	ah, 1			; clear keyboard buffer
	int	keyboard
	pushf
	xor	ah, ah			; and read a key
	int	keyboard
	popf
	jnz	kbdClr

	push	cs
	pop	ds
	assume	ds:codeSeg		; leave DS alone from now on
	mov	si, offset save25
	mov	es, scrSeg
	mov	di, row25offset
	mov	cx, 80
	rep	movsw			; restore row 25

	cmp	al, 27			; exit if Esc
	jne	notEsc
	  jmp	prtDone
notEsc:
	and	al, 0DFh		; convert lower case --> upper

	xor	ch, ch			; CH = char row
	xor	dh, dh			; DH = dot row
	mov	paper216ths, 24
	mov	dotsPerPass, 8
	cmp	al, 'G'
	je	doGraphics

	dec	ch			; double strike starts at char row -1
	mov	dh, 10			; dot row 10 (to do the first strike
	mov	paper216ths, 12 	; of the top 4 dot lines of row 0)
	mov	dotsPerPass, 4
	cmp	al, 'D'
	je	doGraphics

oldDump:
	call	oldCursor
	xor	dx, dx
	mov	es, dx
	mov	es:statusByte, 0
	pushf
	call	SaveInt 		; call the other dump routine
	jmp	exit

doGraphics:
	mov	al, CR
	call	prtChar 		; CR-LF to tension paper
	mov	al, LF
	call	prtChar

nextRow:				; here to begin a character row
	push	cx
	push	dx
	mov	dh, ch
	xor	dl, dl
	mov	bh, pageNo
	mov	ah, 2
	int	video			; put a big cursor on current row
	mov	cx, bigCrs
	mov	ah, 1
	int	video
	pop	dx
	pop	cx

	mov	cl, 79
chkNxtChr:				; here to check a char col for nonblank
	mov	dl, 7
chkNxtDotCol:				; here to check a dot col for nonblank
	call	getDotCol
	test	al, al
	jnz	startRow
	dec	dl
	jge	chkNxtDotCol
	dec	cl
	jge	chkNxtChr
	jmp	advPaper		; nothing at to print on this row
startRow:
	mov	lastCol, cl
	inc	cl
	mov	al, 9
	mul	cl
	mov	bx, ax			; bx = number of dot cols to print

	mov	al, ESC
	call	prtChar
	mov	al, '*'
	call	prtChar 		; set 720 dot graphics mode
	mov	al, 6
	call	prtChar
	mov	al, bl			; with the exact number of dots
	call	prtChar
	mov	al, bh
	call	prtChar

	mov	cl, 0			; CL = char col
nextChar:				; here to dump one character column
	mov	dl, 7			; DL = dot col
nextCol:				; here for each dot column
	call	getDotCol
	call	prtChar

	dec	dl
	cmp	dl, -1
	jge	nextCol

	inc	cl
	cmp	cl, lastCol
	jle	nextChar

advPaper:
	mov	al, CR
	call	prtChar
	mov	al, ESC
	call	prtChar
	mov	al, "J"
	call	prtChar
	mov	al, paper216ths
	call	prtChar

	add	dh, dotsPerPass
	cmp	dh, 14
	jge	sub14
	  jmp	nextRow
sub14:
	sub	dh, 14
	inc	ch
	cmp	ch, 25
	jge	prtDone
	  jmp	nextRow

prtDone:
	call	oldCursor
	xor	al, al
	jmp short getOut
prtErr:
	call	oldCursor
	mov	al, 0FFh
getOut:
	xor	dx, dx
	mov	es, dx
	mov	es:statusByte, al
exit:
	pop	bp
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	pop	es
	pop	ds
	iRet

printScreen	endP


; Call with CH=char row, CL=char col, DH=topmost dot row, DL=dot col.
; Returns with the dot column byte for printing in AL.
getDotCol   proc    near

	push	bx
	xor	bx, bx			; BH=dot row offset, BL=dot accumulator
nextDot:				; here for each dot vertically
	push	dx
	add	dh, bh
	call	getDot
	pop	dx

	shl	bl, 1
	or	bl, al
	inc	bh
	cmp	bh, 8
	jl	nextDot

	mov	al, bl
	pop	bx
	ret

getDotCol   endP


; Call with CH=char row, CL=char col, DH=dot row, DL=dot col.
; Returns with the dot in AL bit 0.
getDot	proc	near

	push	bx
	push	cx
	push	dx

	cmp	dh, 14			; are we really in next char row?
	jl	gd1
	inc	ch			; yes, adjust char and dot rows
	sub	dh, 14
gd1:
	xor	al, al
	or	ch, ch
	jl	gdRet
	cmp	ch, 25
	jge	gdRet			; return 0 if outside screen bounds

	call	getCA			; AH = attr, AL = char

	or	dl, dl			; special check for dot col "-1"
	jge	gd2
	cmp	al, 192
	jl	gd3
	cmp	al, 223
	jle	gd4
gd3:	xor	al, al			; col -1 not in 192..223 is 0
	jmp	gd5
gd4:	xor	dl, dl			; col -1 in 192..223 duplicates col 0
gd2:
	mov	bl, al
	xor	bh, bh
	shl	bx, 1
	shl	bx, 1
	shl	bx, 1
	push	dx
	mov	dl, dh
	xor	dh, dh
	add	bx, dx			; BX = (chr*8) + dotRow
	pop	dx

	cmp	dh, 8
	jl	gd6
	add	bx, 2040		; dot rows 8-13 are higher in ROM
gd6:
	mov	al, cgData[bx]		; get the character data
	mov	cl, dl
	shr	al, cl			; shift dot into position
	and	al, 1
gd5:
	and	ah, 77h
	cmp	ah, 70h 		; check for reverse video
	jne	gdRet
	xor	al, 1			; yes, toggle the dot
gdRet:
	pop	dx
	pop	cx
	pop	bx
	ret

getDot	endP


; Call with CH=row, CL=col.  Returns with AH=attribute, AL=character.
getCA	proc	near

	push	bx
	push	cx

	mov	al, 80
	imul	ch
	xor	ch, ch
	add	ax, cx
	shl	ax, 1
	mov	bx, ax
	mov	ax, scrSeg
	mov	es, ax
	mov	ax, es:[bx]

	pop	cx
	pop	bx
	ret

getCA	endP


;prints the character in AL
prtChar proc	near

	push	dx
	xor	dx, dx
	xor	ah, ah
	int	17h
	pop	dx
	test	ah, 25h
	jz	prtRet
	pop	dx		; get rid of our return address
	jmp	prtErr

prtRet: ret

prtChar endP


; restores user's cursor
oldCursor   proc    near

	push	cs
	pop	ds

	mov	bh, pageNo
	mov	dx, crsPos
	mov	ah, 2
	int	video			; restore cursor position

	mov	cx, crsType
	mov	ah, 1
	int	video			; and type

	ret

oldCursor   endP

codeSeg endS

	end	printScreen
