'OHRRPGCE - Some utility code
'
'Please read LICENSE.txt for GPL License details and disclaimer of liability
'See README.txt for code docs and apologies for crappyness of this code ;)
'
' This file contains utility subs and functions which would be useful for
' any FreeBasic program. Nothing in here can depend on Allmodex, nor on any
' gfx or music backend, nor on any other part of the OHR

'$INCLUDE: 'compat.bi'

FUNCTION bound (n, lowest, highest)
bound = n
IF n < lowest THEN bound = lowest
IF n > highest THEN bound = highest
END FUNCTION

FUNCTION large (n1, n2)
large = n1
IF n2 > n1 THEN large = n2
END FUNCTION

FUNCTION loopvar (var, min, max, inc)
a = var + inc
IF a > max THEN a = a - ((max - min) + 1): loopvar = a: EXIT FUNCTION
IF a < min THEN a = a + ((max - min) + 1): loopvar = a: EXIT FUNCTION
loopvar = a
END FUNCTION

FUNCTION small (n1, n2)
small = n1
IF n2 < n1 THEN small = n2
END FUNCTION

FUNCTION trimpath$ (filename$)
'return the filename without path
IF NOT INSTR(filename$,SLASH) THEN RETURN filename$
FOR i = LEN(filename$) TO 1 STEP -1
 IF MID$(filename$, i, 1) = SLASH THEN i += 1 : EXIT FOR
NEXT
RETURN MID$(filename$, i)
END FUNCTION

FUNCTION trimextension$ (filename$)
'return the filename without extension
IF NOT INSTR(filename$,".") THEN RETURN filename$
FOR i = LEN(filename$) TO 1 STEP -1
 IF MID$(filename$, i, 1) = "." THEN i -= 1 : EXIT FOR
NEXT
RETURN MID$(filename$, 1, i)
END FUNCTION

FUNCTION anycase$ (filename$)
 'make a filename case-insensitive
#IFDEF __FB__LINUX__
 DIM ascii AS INTEGER
 result$ = ""
 FOR i = 1 TO LEN(filename$)
  ascii = ASC(MID$(filename$, i, 1))
  IF ascii >= 65 AND ascii <= 90 THEN
   result$ = result$ + "[" + CHR$(ascii) + CHR$(ascii + 32) + "]"
  ELSEIF ascii >= 97 AND ascii <= 122 THEN
   result$ = result$ + "[" + CHR$(ascii - 32) + CHR$(ascii) + "]"
  ELSE
   result$ = result$ + CHR$(ascii)
  END IF
 NEXT i
 RETURN result$
#ELSE
 'Windows filenames are always case-insenstitive
 RETURN filename$
#ENDIF
END FUNCTION
