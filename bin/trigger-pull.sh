#!/bin/bash
# Listen for IMAGE_COMPLETE, pull the one named file, announce it.
#
# ip-add-membership takes an interface name, never an address; the address
# form fails with ENODEV. IFACE is derived per machine by setup.sh.
#
# The name is a path relative to the image root, such as
# 20260828/img_0001.fits. rsync --relative reproduces that path under
# INCOMING_DIR, so this writes into the same tree the 3 second poll builds. A
# flat copy would create a second, colliding copy of every image.
. /etc/cryoscope/site.conf
. /etc/cryoscope/machine.conf

socat -u "UDP4-RECV:$MCAST_PORT,ip-add-membership=$MCAST_GROUP:$IFACE,reuseaddr" - |
while read -r tag name ts; do
  # Ignore our own IMAGE_AVAILABLE datagrams when they loop back.
  [ "$tag" = "IMAGE_COMPLETE" ] || continue
  case "$name" in
    *.fits) ;;
    *) continue ;;
  esac
  # Reject anything that would write outside INCOMING_DIR. The name arrives
  # over an unauthenticated datagram and is used as a path.
  case "$name" in
    /*|*..*) echo "REJECTED $name" | logger -t trigger-pull; continue ;;
  esac
  # -w 5 rather than -n: the lock is held briefly for one file, so waiting
  # beats dropping it. On timeout the 3 second loop collects it.
  if flock -w 5 "$LOCK_DIR/pull.lock" rsync -a --relative --partial-dir=.rsync-tmp \
       "cryocontrol:$IMAGE_DIR/./$name" "$INCOMING_DIR/" ; then
    printf 'IMAGE_AVAILABLE %s http://%s:%s/%s\n' \
      "$name" "$(hostname)" "$HTTP_PORT" "$name" \
      > "/dev/udp/$MCAST_GROUP/$MCAST_PORT"
    now=$(date +%s.%3N)
    echo "$name $(awk -v a="$now" -v b="$ts" 'BEGIN{printf "%.3f", a-b}')" \
      | logger -t trigger-pull
  else
    echo "FAILED $name" | logger -t trigger-pull
  fi
done
