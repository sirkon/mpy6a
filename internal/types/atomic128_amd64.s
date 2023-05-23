 #include "textflag.h"

TEXT ·setAtomic(SB),NOSPLIT,$0-24
    MOVQ ptr+0(FP), BP
    MOVQ ptr+8(FP), BX
    MOVQ ptr+16(FP), CX
    MOVQ 0(BP), AX
    MOVQ 8(BP), DX
setIndexLoop:
    LOCK  
    CMPXCHG16B(BP)
    JE done
    PAUSE
    JMP setIndexLoop
done:
    RET

TEXT ·getAtomic(SB),NOSPLIT,$0-24
    MOVQ ptr+0(FP), BP
    XORQ AX, AX
    XORQ BX, BX
    XORQ CX, CX
    XORQ DX, DX
    LOCK 
    CMPXCHG16B (BP)
    MOVQ AX, ptr+8(FP)
    MOVQ DX, ptr+16(FP)
    RET

