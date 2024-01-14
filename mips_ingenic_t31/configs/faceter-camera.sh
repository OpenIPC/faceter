#!/bin/sh
cronTask="35 2 * * * sleep $(($RANDOM%5+1))m; reboot"
cronFile="/etc/crontabs/root"

grep 'reboot' $cronFile || echo "$cronTask" >> $cronFile

while true
do
faceter-camera 2>&1 | logger -t faceter-agent
sleep 10s
done
