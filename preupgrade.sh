#!/bin/bash
# Back up configuration and state before LoxBerry replaces the plugin folders.
# Backup goes to a fixed folder so it does not depend on installer arguments.
PDIR=$3
BK=$LBHOMEDIR/data/system/tmp/${PDIR}_upgrade
rm -rf "$BK"; mkdir -p "$BK/config" "$BK/data"
cp -p $LBPCONFIG/$PDIR/*.json "$BK/config/" 2>/dev/null
cp -p $LBPDATA/$PDIR/*.json "$BK/data/" 2>/dev/null
if [ -f "$LBPDATA/$PDIR/alarmd.pid" ]; then kill "$(cat $LBPDATA/$PDIR/alarmd.pid)" 2>/dev/null; fi
echo "<INFO> Backed up: $(ls $BK/config $BK/data 2>/dev/null | grep json | tr '\n' ' ') to $BK"
exit 0
