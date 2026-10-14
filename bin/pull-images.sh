#!/bin/bash
# The 3 second polling pull. The floor beneath the trigger: if the trigger
# dies, latency degrades to 3 seconds rather than to nothing.
#
# Prohibited flags:
#   --delete            would destroy the archive; cryocontrol is cleared by
#                       design
#   --inplace --append  defeat the atomic rename; a partial file becomes
#                       visible to readers
. /etc/cryoscope/site.conf

while true; do
  flock -n "$LOCK_DIR/pull.lock" \
    rsync -a --partial-dir=.rsync-tmp --exclude='*.writing' \
      "cryocontrol:$IMAGE_DIR/" "$INCOMING_DIR/"
  sleep 3
done
