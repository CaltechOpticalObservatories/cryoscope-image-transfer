#!/bin/bash
# Emit IMAGE_COMPLETE on the multicast group when the camera renames a
# completed FITS file into place. Fire and forget: no listener can stall it.
#
# The camera writes into dated subdirectories, /images/YYYYMMDD/, so the watch
# is recursive. inotifywait adds a watch for each directory created while it is
# running, so the nightly rollover needs no restart.
#
# The name emitted is the path relative to IMAGE_DIR, for example
# 20260828/img_0001.fits. It is one whitespace-free token, so the wire format
# is unchanged, and a consumer appends it to the server root to build a URL.
. /etc/cryoscope/site.conf

inotifywait -m -q -r -e moved_to --format '%w%f' "$IMAGE_DIR/" | while read -r p; do
  case "$p" in
    *.fits) ;;
    *) continue ;;
  esac
  # Strip the image root, leaving the path the archive is keyed by.
  rel=${p#"$IMAGE_DIR"/}
  printf 'IMAGE_COMPLETE %s %s\n' "$rel" "$(date +%s.%3N)" \
    > "/dev/udp/$MCAST_GROUP/$MCAST_PORT"
done
