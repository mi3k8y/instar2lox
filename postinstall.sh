#!/bin/bash
PDIR=$3
PVERSION=$4
chmod 755 $LBPBIN/$PDIR/worker.pl $LBPBIN/$PDIR/alarmd.pl
chmod 755 $LBHOMEDIR/webfrontend/htmlauth/plugins/$PDIR/index.cgi
chmod 755 $LBHOMEDIR/system/cron/cron.01min/$PDIR 2>/dev/null || true
chmod 700 $LBPDATA/$PDIR
if [ -f "$LBPCONFIG/$PDIR/instar2lox.json" ]; then chmod 600 $LBPCONFIG/$PDIR/instar2lox.json; fi
rm -f $LBPDATA/$PDIR/alarmd.pid
echo "<OK> instar2lox $PVERSION installed."
exit 0
