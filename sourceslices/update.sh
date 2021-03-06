#!/bin/sh

# This could probably be done better inside the SConscript file.

DIR=`echo "${0}" | sed -e s/"update.sh$"/""/`
cd "${DIR}"

echo "'This file automatically generated by sourceslices/update.sh" > ../sourceslices.bi

for SLFILE in *.slice ; do
  SLFUNC=`echo "${SLFILE}" | sed -e s/"\.slice$"/""/`
  SLBAS=`echo "${SLFUNC}.bas"`
  ../slice2bas "${SLFUNC}" "${SLFILE}" - >> ../sourceslices.bi
done
