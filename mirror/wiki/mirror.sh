#/bin/sh

URL="http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/"

rm -R gilgamesh.hamsterrepublic.com index.html date.txt url.txt mirror.tar.bz2 > /dev/null 2>&1

echo "mirroring ${URL}"

httrack --quiet --extended-parsing=YES \
  "${URL}" \
  +"*hamsterrepublic*.gif" \
  +"*hamsterrepublic*.png" \
  +"*hamsterrepublic*.jpg" \
  +"*hamsterrepublic*.jpeg" \
  -"*hamsterrepublic.com/bobcomic*" \
  -"*Special:*" \
  +"*Special:Categories*" \
  -"*Special:Categories&article=*" \
  -"*Special:Userlogin*" \
  -"*action=*" \
  -"*diff=*" \
  -"*&limit*" \
  -"*&hide*" \
  -"*&printable=*" \
  -"*&wpDestFile=*" \
  -"*oldid=*" \
  -"*&until=*" \
  -"*&from=*" \
  +"*/index.php?title=-&action=raw&gen=js" \
  +"*/index.php?title=-&amp;action=raw&amp;gen=css" \
  +"*/index.php?title=MediaWiki:Common.css&*" \
  +"*/index.php?title=MediaWiki:Monobook.css&*" \
  +"*/index.php?title=-*gen=css*" \
  +"*/favicon.ico" \
  > httrack.out 2>&1

SEGFAULT=`grep "Segmentation fault" httrack.out`
rm httrack.out
if [ -s "${SEGFAULT}" ] ; then
  echo "SANITY CHECK FAILED: Segmentation fault while downloading"
  exit 1
fi

echo "manually download Browser-specific files"
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/common/IEFixes.js http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/common/IEFixes.js
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE50Fixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE60Fixes.css
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE55Fixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE60Fixes.css
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE60Fixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE60Fixes.css
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE70Fixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/IE70Fixes.css
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/Opera7Fixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/Opera7Fixes.css
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/Opera9Fixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/Opera9Fixes.css
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/KHTMLFixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/KHTMLFixes.css
wget -q -O gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/FF2Fixes.css http://gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/skins/monobook/FF2Fixes.css

rm backblue.gif fade.gif cookies.txt hts-log.txt > /dev/null 2>&1
rm -R hts-cache > /dev/null 2>&1

# sanity check

CHECK=`grep "OHRRPGCE" gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/index.php/Main_Page.html | wc -c`
if [ ${CHECK} -lt 5 ] ; then
  echo "SANITY CHECK FAILED: OHRRPGCE not found in Main Page"
  exit 1
fi

SIZE=`du -s | cut -f 1`
printf "Mirror size: %d k\n" "${SIZE}"
if [ ${SIZE} -lt 5000 ] ; then
  echo "SANITY CHECK FAILED: Mirror too small"
  exit 1
fi

echo fix index
rm index.html
echo "<?php header(\"Location: index.php/Main_Page.html\"); ?>" > index.php
echo "<?php header(\"Location: gilgamesh.hamsterrepublic.com/wiki/ohrrpgce/index.php/Main_Page.html\"); ?>" > index.php.mirror


date "+%Y-%m-%d" > date.txt
echo ${URL} > url.txt

echo "compressing..."
tar -jcf mirror.tar.bz2 ./*

echo "uploading stable to dreamhost..."
scp -p mirror.tar.bz2 james_paige@motherhamster.org:tmp/
ssh james_paige@motherhamster.org sh script/ohrrpgce-mirror.sh

echo "uploading mirror..."
scp -p mirror.tar.bz2 james_paige@motherhamster.org:mirror.motherhamster.org/
ssh james_paige@motherhamster.org mirror.motherhamster.org/expand.sh wiki

echo "uploading mirror to sourceforge"
ssh bob_the_hamster,ohrrpgce@shell.sourceforge.net create
scp -p mirror.tar.bz2 bob_the_hamster,ohrrpgce@shell.sourceforge.net:tmp/
ssh bob_the_hamster,ohrrpgce@shell.sourceforge.net sh script/ohrrpgce-mirror.sh
ssh bob_the_hamster,ohrrpgce@shell.sourceforge.net shutdown
