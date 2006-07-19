'OHRRPGCE GAME - Globals
'(C) Copyright 1997-2005 James Paige and Hamster Republic Productions
'Please read LICENSE.txt for GPL License details and disclaimer of liability
'See README.txt for code docs and apologies for crappyness of this code ;)
'

'$INCLUDE: 'udts.bi'

'Misc game globals
COMMON SHARED game$, sourcerpg$, gen(), tag(), timing(), global(), carray(), csetup(), gotj(), joy(), veh(), hero(), pal16(), names$(), eqstuf(), lmp(), bmenu(), spell(),  _
exlev&(), gold&, herobits%(), itembits%(), fmvol, hmask(), speedcontrol, deferpaint, tmpdir$, nativehbits(), catx(), caty(), catz(), catd(), herospeed(), xgo(), ygo(), mapx, mapy, presentsong, keyv(), foemaph, lockfile,  _
lastsaveslot, plotstring$(), plotstrX(), plotstrY(), plotstrCol(), plotstrBGCol(), plotstrBits(), npcs(), wtog(), catermask(), framex, framey, gmap(), scroll(), exename$, defbinsize(), curbinsize(), lumpmod(), abortg, usepreunlump%
COMMON SHARED npc() as NPCInst
COMMON SHARED inventory() as InventSlot

'Script globals
COMMON SHARED script(), heap(), astack(), scrat(), retvals(), nowscript, scriptret, nextscroff

'Battle globals
COMMON SHARED battlecaption$, battlecaptime, battlecapdelay, bstackstart, learnmask()
