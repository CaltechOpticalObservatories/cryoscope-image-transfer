#!/bin/bash
#
# sweep.sh -- reference eavesdropper, reconciliation path.
#
# Lists the image directory every 30 sec and fetches anything missing locally.
#
# Run alongside eavesdrop.sh when that script is in fetching mode (FETCH=1).
# There it is not optional: it covers dropped datagrams, time spent powered
# off, and every image delivered by a fallback path, none of which announce.
#
# Do not run it when eavesdrop.sh is in notification-only mode (FETCH=0). This
# script fetches unconditionally, and running it would defeat that mode.
#
# All settings are read once at startup. Changing one means editing this file
# and restarting the script.
#
#     ./sweep.sh

# ---------------------------------------------------------------- settings --
#
# DATA names the machine currently serving. It is the one address an
# eavesdropper cannot learn from a datagram, because this loop runs on a timer
# with nothing to read. Change it by hand when the active machine changes.
#
# LAYOUT and DEST must match eavesdrop.sh, or the two scripts will not see each
# other's files and will fetch everything twice.

DATA=http://concordia1:8080
LAYOUT=mirror
DEST=$HOME/images
INTERVAL=30

# ---------------------------------------------------------------------------

set -u
mkdir -p "$DEST"

# The image root is one level of dated directories holding the images, so the
# listing is taken in two steps: the directories, then the files in each. The
# server returns a JSON autoindex for a plain GET, giving a type per entry, so
# nothing here has to guess a directory from its name.
#
# Emits one "type name" line per entry.
list_json() {
  curl -s -m 20 "$1" \
    | grep -o '"name":"[^"]*", *"type":"[^"]*"' \
    | sed 's/"name":"\(.*\)", *"type":"\(.*\)"/\2 \1/'
}

fetch_one() {           # fetch_one RELATIVE_PATH
  local p=$1 base out
  if [ "$LAYOUT" = flat ]; then
    base=${p##*/}
    out="$DEST/$base"
    if [ -n "${SEEN[$base]:-}" ]; then
      # This basename is already claimed. Same path means it is already here.
      [ "${SEEN[$base]}" = "$p" ] && return 0
      # A different path wants the same name. Report it once, keep the first.
      if [ -z "${REPORTED[$p]:-}" ]; then
        echo "collision $p: $out already holds ${SEEN[$base]}, not overwritten"
        REPORTED[$p]=1
      fi
      return 0
    fi
    # Unclaimed. A file already on disk is from an earlier run of this script.
    SEEN[$base]=$p
    [ -e "$out" ] && return 0
  else
    out="$DEST/$p"
    [ -e "$out" ] && return 0
    mkdir -p "$(dirname "$out")" || return 0
  fi
  curl -s -f -m 300 -o "$out.part" "$DATA/$p" \
    && mv "$out.part" "$out" \
    && echo "swept $p"
}

declare -A SEEN REPORTED

while true; do
  while read -r type name; do
    [ -n "$name" ] || continue
    case "$name" in
      .*) continue ;;               # the server denies dotted paths anyway
    esac
    if [ "$type" = directory ]; then
      while read -r ftype fname; do
        [ "$ftype" = file ] || continue
        case "$fname" in
          *.fits) fetch_one "$name/$fname" ;;
        esac
      done < <(list_json "$DATA/$name/")
    elif [ "$type" = file ]; then
      case "$name" in
        *.fits) fetch_one "$name" ;;
      esac
    fi
  done < <(list_json "$DATA/")
  sleep "$INTERVAL"
done
