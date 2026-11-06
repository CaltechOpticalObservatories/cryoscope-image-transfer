#!/bin/bash
#
# eavesdrop.sh -- reference eavesdropper, notified path.
#
# Joins the multicast group and acts on each announcement. Two modes, set by
# FETCH below:
#
#   FETCH=1   notification and image. Fetches each file as it is announced.
#             Run sweep.sh alongside; it covers what this misses.
#   FETCH=0   notification only. Reports each completed exposure and writes
#             nothing to disk. sweep.sh is not needed and should not be run.
#
# The mode is read once at startup. Changing it means editing this file and
# restarting the script.
#
# This is the behaviour an eavesdropper must implement. It is not part of the
# image-transfer kit and nothing upstream depends on it.
#
#     ./eavesdrop.sh

# ---------------------------------------------------------------- settings --
#
# IFACE is an interface NAME such as eno2, not an address. The address form
# fails with ENODEV. On a machine with several adapters, including any VPN
# adapter, name the one on the instrument LAN explicitly.
#
# FETCH selects the mode described above. With FETCH=0, DEST and LAYOUT are
# unused and nothing is written.
#
# LAYOUT selects how fetched images are stored. The announced name is a path
# relative to the image directory root, such as 20260828/img_0001.fits.
#
#   mirror   reproduce that path under DEST. Cannot lose an image.
#   flat     write the bare filename into DEST. Simpler for a consumer that
#            only wants the newest frame, but two nights that reuse a
#            filename collide. This script refuses to overwrite and reports
#            the collision rather than losing the older image.
#
# sweep.sh must be set to the same LAYOUT and DEST, or the two scripts will
# not see each other's files and will fetch everything twice.

IFACE=eno2
FETCH=1
LAYOUT=mirror
GROUP=239.192.1.1
PORT=5555
DEST=$HOME/images

# ---------------------------------------------------------------------------

set -u
[ "$FETCH" = 1 ] && mkdir -p "$DEST"

socat -u "UDP4-RECV:$PORT,ip-add-membership=$GROUP:$IFACE,reuseaddr" - |
while read -r tag name url; do
  if [ "$tag" = "IMAGE_COMPLETE" ]; then
    # The exposure finished on the acquisition computer. Nothing is fetchable
    # yet. This is the notification, and it arrives without traversing the
    # transfer path.
    echo "notified $name at $(date +%s.%3N)"
    continue
  fi

  # Ignore anything that is not a message this script handles, rather than
  # treating it as an error, so the protocol can be extended.
  [ "$tag" = "IMAGE_AVAILABLE" ] || continue

  [ "$FETCH" = 1 ] || continue

  # The name arrives over an unauthenticated datagram and is used as a path.
  case "$name" in
    /*|*..*) echo "rejected $name" ; continue ;;
  esac

  if [ "$LAYOUT" = flat ]; then
    out="$DEST/${name##*/}"
    if [ -e "$out" ]; then
      echo "collision $name: $out already exists, not overwritten"
      continue
    fi
  else
    out="$DEST/$name"
    mkdir -p "$(dirname "$out")" || continue
  fi

  # The URL comes from the datagram and is never constructed here. This is what
  # makes fetches follow a failover without reconfiguration.
  curl -s -f -o "$out.part" "$url" \
    && mv "$out.part" "$out" \
    && echo "fetched $name at $(date +%s.%3N)"
done
