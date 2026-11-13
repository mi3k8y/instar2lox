#!/bin/bash
PDIR=$3
BK=$LBHOMEDIR/data/system/tmp/${PDIR}_upgrade
if [ -d "$BK" ]; then
  mkdir -p $LBPCONFIG/$PDIR $LBPDATA/$PDIR
  cp -p "$BK"/config/*.json $LBPCONFIG/$PDIR/ 2>/dev/null
  cp -p "$BK"/data/*.json $LBPDATA/$PDIR/ 2>/dev/null
  echo "<OK> Restored configuration: $(ls $LBPCONFIG/$PDIR | tr '\n' ' ')"
  rm -rf "$BK"
else
  echo "<WARNING> No backup found in $BK - configuration starts empty."
fi
chmod 600 $LBPCONFIG/$PDIR/instar2lox.json 2>/dev/null
chmod 755 $LBPBIN/$PDIR/worker.pl $LBPBIN/$PDIR/alarmd.pl $LBHOMEDIR/webfrontend/htmlauth/plugins/$PDIR/index.cgi
rm -f $LBPDATA/$PDIR/alarmd.pid
# Start the worker (and with it the alarm listener) now instead of waiting for cron.
export PERL5LIB=$LBHOMEDIR/libs/perllib
nohup /usr/bin/perl $LBPBIN/$PDIR/worker.pl > /dev/null 2>&1 &
echo "<INFO> Alarm listener start requested."
exit 0
