 #include "textflag.h"

TEXT ·setAtomic(SB),NOSPLIT,$24
    MOVD ptr+0(FP), R1
    MOVD ptr+8(FP), R4
    MOVD ptr+16(FP), R5
setIndexLoop:
    LDXP (R1), (R2, R3)
    STLXP (R4, R5), (R1), R6
    CBNZ R6, setIndexLoop
    RET

TEXT ·getAtomic(SB),NOSPLIT,$24
    MOVD ptr+0(FP), R1
    LDXP (R1), (R2, R3)
    MOVD R2, ptr + 8(FP)
    MOVD R3, ptr + 16(FP)
    RET
