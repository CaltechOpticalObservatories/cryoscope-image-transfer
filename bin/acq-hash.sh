#!/bin/bash
# Record the SHA-256 of every completed FITS image in ACQ_MANIFEST, one line
# per image:
#
#     20260828/img_0001.fits <sha256> <bytes> <unix time hashed>
#
# The name is the path relative to IMAGE_DIR, as notify-images.sh emits it. An
# image is deleted from cryocontrol only when a concordia's own hash of its
# copy matches the hash here, so an image missing from this manifest is kept.
#
# IMAGE_DIR is scanned every 30 seconds for images not yet in the manifest,
# rather than watched. A scan cannot miss an event, and the first scan after
# any downtime is the catch-up. It costs one directory walk and one sort; the
# hashing is the expensive part. A just-renamed image is usually still in the
# page cache, so hashing it rarely touches the disk. The unit runs this at idle
# CPU priority; its idle I/O class takes effect only under the BFQ scheduler.
#
# The camera writes NAME.fits.writing and renames it when complete, so a file
# named *.fits is never partial.
#
# Append-only with a single writer, so nothing locks.
. /etc/cryoscope/site.conf

touch "$ACQ_MANIFEST" || exit 1

# A crash mid-write can leave the last line unterminated, and the next record
# would be appended to it.
[ -n "$(tail -c 1 "$ACQ_MANIFEST")" ] && echo >> "$ACQ_MANIFEST"

while true; do
  LC_ALL=C comm -23 \
    <(find "$IMAGE_DIR" -type f -name '*.fits' -printf '%P\n' | LC_ALL=C sort) \
    <(cut -d ' ' -f 1 "$ACQ_MANIFEST" | LC_ALL=C sort) |
  while read -r rel; do
    if sum=$(sha256sum "$IMAGE_DIR/$rel") && bytes=$(stat -c %s "$IMAGE_DIR/$rel"); then
      printf '%s %s %s %s\n' "$rel" "${sum%% *}" "$bytes" "$(date +%s)" >> "$ACQ_MANIFEST"
    else
      echo "FAILED $rel" | logger -t acq-hash
    fi
  done
  sleep 30
done
