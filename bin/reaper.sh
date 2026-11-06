#!/bin/bash
# Delete images from IMAGE_DIR once a concordia holds a verified copy, when the
# disk fills. Run every 10 minutes by reaper.timer.
#
# Each run fetches data.manifest from every concordia that answers and joins it
# with ACQ_MANIFEST by name. An image is verified when a concordia's hash and
# size of its own copy match the hash and size recorded here. The same name
# with a different hash or size is a MISMATCH: logged as an error, recorded
# once in mismatch.txt, and that image is never deleted.
#
# The comparison runs every time. Deletion runs only at or above REAP_START_PCT
# used, and takes images through four gates, each sufficient on its own to
# prevent a wrong deletion:
#
#     1. verified, and never recorded as a mismatch
#     2. modified at least REAP_MIN_AGE_HOURS ago
#     3. oldest first, and never one of the newest REAP_KEEP_NEWEST images
#     4. only until REAP_STOP_PCT used
#
# With REAP_DRY_RUN=1 (anything but 0) the images that would be deleted are
# listed in would-delete.txt and nothing is deleted. Each deletion is appended
# to deleted.txt. All three records are kept beside ACQ_MANIFEST.
#
# Authority to delete stays here. A concordia only publishes what it holds.
. /etc/cryoscope/site.conf

DIR=$(dirname "$ACQ_MANIFEST")
MISMATCHES=$DIR/mismatch.txt
DELETED=$DIR/deleted.txt
WOULD=$DIR/would-delete.txt

# join, sort and comm must agree on one collation.
export LC_ALL=C

log() { logger -t reaper "$*"; }
err() { logger -p user.err -t reaper "$*"; }

for v in REAP_START_PCT REAP_STOP_PCT REAP_MIN_AGE_HOURS REAP_KEEP_NEWEST; do
    eval "val=\${$v:-}"
    case "$val" in
        ''|*[!0-9]*) err "$v='$val' in site.conf is not a whole number. Nothing done."; exit 1 ;;
    esac
done
[ "$REAP_STOP_PCT" -lt "$REAP_START_PCT" ] || {
    err "REAP_STOP_PCT ($REAP_STOP_PCT) must be below REAP_START_PCT ($REAP_START_PCT). Nothing done."
    exit 1
}
DRY=1
[ "${REAP_DRY_RUN:-1}" = 0 ] && DRY=0

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# complete FILE -- the well-formed lines of a manifest: four fields, a 64-digit
# hex hash, a whole-number size. An unterminated last line is one being
# written as it was read, and is dropped.
complete() {
    { if [ -n "$(tail -c 1 "$1")" ]; then sed '$d' "$1"; else cat "$1"; fi; } \
        | awk 'NF == 4 && length($2) == 64 && $2 !~ /[^0-9a-f]/ && $3 !~ /[^0-9]/'
}

# ------------------------------------------------------------------ compare --

: > "$T/remote"
FROM=""
for ip in "$CONCORDIA1_IP" "$CONCORDIA2_IP"; do
    if curl -sf --connect-timeout 3 -m 30 -o "$T/fetched" \
            "http://$ip:$HTTP_PORT/manifests/data.manifest"; then
        complete "$T/fetched" | awk -v ip="$ip" '{ print $1, $2, $3, ip }' >> "$T/remote"
        FROM="$FROM $ip"
    fi
done
# Both concordias may report the same image; a line from each is kept.
sort -u "$T/remote" | sort -s -k1,1 -o "$T/remote"

# Only images still here matter.
find "$IMAGE_DIR" -type f -name '*.fits' -printf '%T@ %P\n' | sort -k2,2 > "$T/present"
complete "$ACQ_MANIFEST" | sort -k1,1 -u \
    | join -1 1 -2 2 -o 1.1,1.2,1.3,2.1 - "$T/present" > "$T/local"

# name acq-sha acq-bytes mtime concordia-sha concordia-bytes concordia-ip
join "$T/local" "$T/remote" > "$T/joined"

awk '$2 != $5 || $3 != $6' "$T/joined" > "$T/bad"
cut -d ' ' -f 1 "$T/bad" | sort -u > "$T/badnames"
awk '$2 == $5 && $3 == $6 { print $1 }' "$T/joined" | sort -u \
    | comm -23 - "$T/badnames" > "$T/verified"

touch "$MISMATCHES"
cut -d ' ' -f 1 "$MISMATCHES" | sort -u > "$T/known"
while read -r name sha bytes _ csha cbytes ip; do
    grep -qxF "$name" "$T/known" && continue
    err "MISMATCH $name here $sha $bytes, at $ip $csha $cbytes"
    printf '%s %s %s %s %s %s %s\n' "$name" "$sha" "$bytes" "$ip" "$csha" "$cbytes" "$(date +%s)" \
        >> "$MISMATCHES"
    echo "$name" >> "$T/known"
done < "$T/bad"

# A name once recorded stays undeletable, even when the concordia that reported
# it no longer answers and another holds a matching copy.
sort -u "$T/known" | comm -23 "$T/verified" - > "$T/ok"
mv "$T/ok" "$T/verified"

NPRESENT=$(wc -l < "$T/present")
NVERIFIED=$(wc -l < "$T/verified")
NBAD=$(wc -l < "$T/badnames")

# ------------------------------------------------------------------- delete --

read -r USED AVAIL < <(df -B1 --output=used,avail "$IMAGE_DIR" | tail -1)
TOTAL=$((USED + AVAIL))
pct() { echo $(( ($1 * 100 + TOTAL - 1) / TOTAL )); }
PCT=$(pct "$USED")

SUMMARY="${PCT}% used; $NPRESENT images, $NVERIFIED verified, $NBAD mismatched; manifests from:${FROM:- none}"

if [ "$PCT" -lt "$REAP_START_PCT" ]; then
    log "$SUMMARY"
    [ "$DRY" -eq 1 ] && : > "$WOULD"
    exit 0
fi

NEED=$((USED - TOTAL * REAP_STOP_PCT / 100))
CUTOFF=$(( $(date +%s) - REAP_MIN_AGE_HOURS * 3600 ))

# Gates 3 and 2 over every image here, then gate 1, then oldest first until
# gate 4 is met.
sort -n -k1,1 "$T/present" | head -n "-$REAP_KEEP_NEWEST" \
    | awk -v c="$CUTOFF" '$1 <= c { print $2, $1 }' | sort -k1,1 \
    | join - "$T/verified" \
    | join - "$T/local" \
    | sort -n -k2,2 \
    | awk -v need="$NEED" 'got >= need { exit } { print $1, $3, $4; got += $4 }' \
    > "$T/plan"

N=0
FREED=0
if [ "$DRY" -eq 1 ]; then
    cp "$T/plan" "$WOULD"
    while read -r _ _ bytes; do N=$((N + 1)); FREED=$((FREED + bytes)); done < "$T/plan"
    log "$SUMMARY; dry run, would delete $N images, $FREED bytes; list in $WOULD"
    AFTER=$(pct $((USED - FREED)))
else
    rm -f "$WOULD"
    while read -r name sha bytes; do
        case "$name" in
            /*|*..*) err "refused to delete $name: not a path inside $IMAGE_DIR"; continue ;;
        esac
        size=$(stat -c %s "$IMAGE_DIR/$name" 2>/dev/null)
        if [ "$size" != "$bytes" ]; then
            err "kept $name: size $size here, $bytes in the manifest"
            continue
        fi
        if rm -f -- "$IMAGE_DIR/$name"; then
            printf '%s %s %s %s\n' "$name" "$sha" "$bytes" "$(date +%s)" >> "$DELETED"
            N=$((N + 1))
            FREED=$((FREED + bytes))
        else
            err "could not delete $name"
        fi
    done < "$T/plan"

    # A dated directory emptied by deletion is removed once it has stayed empty
    # for REAP_MIN_AGE_HOURS, so tonight's is never touched.
    find "$IMAGE_DIR" -mindepth 1 -maxdepth 1 -type d \
        -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' -empty \
        ! -newermt "@$CUTOFF" -delete

    read -r USED AVAIL < <(df -B1 --output=used,avail "$IMAGE_DIR" | tail -1)
    AFTER=$(pct "$USED")
    log "$SUMMARY; deleted $N images, $FREED bytes; now ${AFTER}% used"
fi

if [ "$AFTER" -ge "$REAP_START_PCT" ]; then
    logger -p user.warning -t reaper "still ${AFTER}% used: $((NPRESENT - NVERIFIED)) images here are not verified on any concordia, and $REAP_KEEP_NEWEST newest and any under $REAP_MIN_AGE_HOURS hours old are kept"
fi
exit 0
