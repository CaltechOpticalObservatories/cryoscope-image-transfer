#!/bin/bash
# Record the SHA-256 of every FITS image that has arrived in INCOMING_DIR in
# MANIFEST_DIR/data.manifest, one line per image, in the format of cryocontrol's
# acq.manifest:
#
#     20260828/img_0001.fits <sha256> <bytes> <unix time hashed>
#
# The name is the path relative to INCOMING_DIR, which the transfers build as
# the same tree as IMAGE_DIR on cryocontrol, so a name here is the name there.
# cryocontrol fetches this manifest over HTTP and deletes an image only when
# the hash here matches its own.
#
# INCOMING_DIR is scanned every 30 seconds for images not yet in the manifest,
# rather than watched. A scan cannot miss an event, and the first scan after
# any downtime is the catch-up. The archive here is never cleared, but on a test
# archive of a million images a pass that found nothing new took about half a
# second. The unit runs this at idle CPU priority; its idle I/O class takes
# effect only under the BFQ scheduler.
#
# rsync writes each file under a dotted temporary name and renames it when
# complete, and keeps an interrupted transfer in .rsync-tmp/ under its final
# name. Dotted names are pruned from the scan, so a file named *.fits outside
# them is complete.
#
# Append-only with a single writer, so nothing locks.
. /etc/cryoscope/site.conf

MANIFEST=$MANIFEST_DIR/data.manifest

touch "$MANIFEST" || exit 1

# A crash mid-write can leave the last line unterminated, and the next record
# would be appended to it.
[ -n "$(tail -c 1 "$MANIFEST")" ] && echo >> "$MANIFEST"

while true; do
  LC_ALL=C comm -23 \
    <(find "$INCOMING_DIR" -name '.*' -prune -o -type f -name '*.fits' -printf '%P\n' | LC_ALL=C sort) \
    <(cut -d ' ' -f 1 "$MANIFEST" | LC_ALL=C sort) |
  while read -r rel; do
    if sum=$(sha256sum "$INCOMING_DIR/$rel") && bytes=$(stat -c %s "$INCOMING_DIR/$rel"); then
      printf '%s %s %s %s\n' "$rel" "${sum%% *}" "$bytes" "$(date +%s)" >> "$MANIFEST"
    else
      echo "FAILED $rel" | logger -t arrival-hash
    fi
  done
  sleep 30
done
