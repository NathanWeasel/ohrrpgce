@echo off
IF NOT EXIST game.exe GOTO failed
IF NOT EXIST custom.exe GOTO failed
IF NOT EXIST gfx_%1.bas GOTO failed
IF NOT EXIST music_%2.bas GOTO failed
echo Now uploading the OHR with %1 graphics module, and %2 music module
REM %3 is a suffix for the zip file

del distrib\ohrrpgce-wip-%1-%2%3.zip
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip game.exe custom.exe
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip ohrrpgce.new
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip whatsnew.txt *-binary.txt *-nightly.txt plotscr.hsd svninfo.txt
support\zip -q -r distrib\ohrrpgce-wip-%1-%2%3.zip ohrhelp

IF NOT EXIST distrib\ohrrpgce-wip-%1-%2%3.zip GOTO failed

mkdir sanity
cd sanity
..\support\unzip -qq ..\distrib\ohrrpgce-wip-%1-%2%3.zip
cd ..
IF NOT EXIST sanity\game.exe GOTO sanityfailed
IF NOT EXIST sanity\custom.exe GOTO sanityfailed
rm -r sanity

IF NOT %1==alleg GOTO skipgfxalleg
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip alleg40.dll
:skipgfxalleg

IF NOT %1==sdl GOTO skipgfxsdl
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip SDL.dll
:skipgfxsdl

IF NOT %2==allegro GOTO skipmusalleg
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip alleg40.dll
:skipmusalleg

IF NOT %2==sdl GOTO skipmussdl
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip SDL.dll SDL_mixer.dll
:skipmussdl

IF NOT %2==native GOTO skipmusnative
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip audiere.dll
:skipmusnative

IF NOT %2==native2 GOTO skip2musnative
support\zip -q distrib\ohrrpgce-wip-%1-%2%3.zip audiere.dll
:skip2musnative

pscp -i C:\progra~1\putty\id_rsa.ppk distrib\ohrrpgce-wip-%1-%2%3.zip james_paige@motherhamster.org:HamsterRepublic.com/ohrrpgce/nightly/
GOTO finished

:sanityfailed
del sanity\*.exe
del sanity\*.dll
del sanity\*.txt
del sanity\*.hsd
rmdir sanity

:failed

:finished
