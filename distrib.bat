cd %OHRRPGCE%

del tmp\*.???

ECHO Packaging binary distribution of CUSTOM

copy game.exe tmp
copy game-qb.exe tmp
copy custom.exe tmp
copy customqb.exe tmp
copy hspeak.exe tmp
copy unlump.exe tmp
copy ohrrpgce.mas tmp
copy ohrrpgce.fnt tmp
copy ohrrpgce.new tmp
copy README-custom.txt tmp
copy LICENSE.txt tmp
copy LICENSE-binary.txt tmp
copy whatsnew.txt tmp
copy sample\sample.rpg tmp
copy sample\npc_tag.rpg tmp
copy sample\pstutor.rpg tmp
copy plotscr.hsd tmp
copy scancode.hsi tmp

del distrib\custom.zip

cd tmp
..\support\pkzip ..\distrib\custom.zip *.*
cd ..
support\pkzip distrib\custom.zip import
support\pkzip -P -r distrib\custom.zip import\*.*
support\pkzip distrib\custom.zip docs
support\pkzip -P -r distrib\custom.zip docs\*.*

