#!/bin/bash
#
# check.sh -- read-only diagnostic. Changes nothing.
#
#     check.sh              all checks except the timed transfer test
#     check.sh --transfer   also run the timed rename-to-arrival test, which
#                           creates and removes one zero-byte test file
#
# The transfer test is the only check that writes anything, which is why it is
# opt-in. It exercises the live path, so it emits a real IMAGE_COMPLETE and
# IMAGE_AVAILABLE that every eavesdropper sees. The test file is named
# zz_check_PID.fits so it is recognisable as one.

set -u

CONFDIR=/etc/cryoscope
CONFFILE=site.conf
PASS=0; FAIL=0; SKIP=0

pass() { printf 'PASS  %-34s %s\n' "$1" "${2:-}"; PASS=$((PASS+1)); }
fail() { printf 'FAIL  %-34s %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
skip() { printf 'SKIP  %-34s %s\n' "$1" "${2:-}"; SKIP=$((SKIP+1)); }
head_() { printf '\n--- %s\n' "$1"; }

# unhashed DIR MANIFEST -- the number of images in DIR more than two minutes
# old that are not in MANIFEST. The hash writers scan every 30 seconds, and
# dotted paths are rsync's temporary files.
unhashed() {
    LC_ALL=C comm -23 \
        <(find "$1" -name '.*' -prune -o -type f -name '*.fits' -mmin +2 -printf '%P\n' | LC_ALL=C sort) \
        <(cut -d ' ' -f 1 "$2" | LC_ALL=C sort) | wc -l
}

DO_TRANSFER=0
[ "${1:-}" = "--transfer" ] && DO_TRANSFER=1

printf '================================================================\n'
printf 'Cryoscope check.sh   %s   %s\n' "$(hostname)" "$(date -Is)"
printf '================================================================\n'

# ------------------------------------------------------------ configuration --

head_ "Configuration"

if [ -f "$CONFDIR/$CONFFILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFDIR/$CONFFILE"
    pass "address table present"
    # The table must be byte-identical on every machine. Compare this
    # fingerprint across two outputs to see at a glance whether it is.
    printf 'NOTE  %-34s %s\n' "address table fingerprint" \
        "$(md5sum "$CONFDIR/$CONFFILE" | cut -c1-12)"
else
    fail "address table present" "no $CONFDIR/$CONFFILE -- run setup.sh"
    exit 1
fi

if [ -f "$CONFDIR/machine.conf" ]; then
    # shellcheck source=/dev/null
    . "$CONFDIR/machine.conf"
    pass "machine configuration present" "iface $IFACE, address $MY_IP"
else
    fail "machine configuration present" "no $CONFDIR/machine.conf -- run setup.sh"
    exit 1
fi

HOST=$(hostname)
case "$HOST" in
    cryocontrol) EXPECT_IP=$CRYOCONTROL_IP ;;
    concordia1)  EXPECT_IP=$CONCORDIA1_IP ;;
    concordia2)  EXPECT_IP=$CONCORDIA2_IP ;;
    *) fail "hostname recognised" "$HOST is not one of cryocontrol, concordia1, concordia2"; exit 1 ;;
esac
pass "hostname recognised" "$HOST"

ON_LAN=1
CUR_IP=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
if [ "$CUR_IP" = "$EXPECT_IP" ]; then
    pass "address matches the table" "$CUR_IP"
else
    ON_LAN=0
    if [ "$HOST" = cryocontrol ]; then
        skip "address matches the table" "at $CUR_IP, table says $EXPECT_IP. Cold spare: LAN checks deferred."
    else
        fail "address matches the table" "at $CUR_IP, table says $EXPECT_IP"
    fi
fi

if [ "${MACHINE_ROLE:-}" = data ]; then
    CROLE=$(cat "$CONFDIR/role" 2>/dev/null || echo unknown)
    pass "concordia role" "$CROLE"
fi

# ------------------------------------------------------------------- naming --

head_ "Name resolution"

for n in cryocontrol concordia1 concordia2; do
    a=$(getent hosts "$n" 2>/dev/null | awk '{print $1}' | head -1)
    eval "want=\${$(echo "$n" | tr 'a-z' 'A-Z')_IP}"
    if [ -z "$a" ]; then
        fail "resolves: $n" "no answer"
    elif [ "$a" = "$want" ]; then
        pass "resolves: $n" "$a"
    elif [ "$n" = "$HOST" ] && [ "$a" = "127.0.1.1" ]; then
        # Debian's 127.0.1.1 line precedes our block and answers first for
        # this machine's own name. Peers resolve it from their own hosts file.
        pass "resolves: $n" "127.0.1.1 locally, $want to peers"
    else
        fail "resolves: $n" "$a, but the table says $want"
    fi
done

# ---------------------------------------------------------------- interface --

head_ "Interface"

if ip link show "$IFACE" >/dev/null 2>&1; then
    pass "interface exists" "$IFACE"
    if ip link show "$IFACE" | head -1 | grep -q MULTICAST; then
        pass "multicast flag set"
    else
        fail "multicast flag set" "sudo ip link set $IFACE multicast on"
    fi
else
    fail "interface exists" "$IFACE is gone. Re-run setup.sh."
fi

if bash -c 'exec 3<>/dev/udp/127.0.0.1/9' 2>/dev/null; then
    pass "bash /dev/udp support"
else
    fail "bash /dev/udp support" "the trigger cannot work without it"
fi

# ===================================================== CRYOCONTROL =============

if [ "${MACHINE_ROLE:-}" = emitter ]; then

head_ "Acquisition computer"

[ -d "$IMAGE_DIR" ] && pass "$IMAGE_DIR exists" || fail "$IMAGE_DIR exists"
[ -r "$IMAGE_DIR" ] && pass "$IMAGE_DIR readable by $(id -un)" \
                    || fail "$IMAGE_DIR readable by $(id -un)"

command -v inotifywait >/dev/null && pass "inotify-tools installed" \
                                  || fail "inotify-tools installed"

if systemctl is-enabled --quiet notify-images 2>/dev/null; then
    pass "notify-images enabled"
else
    fail "notify-images enabled" "sudo systemctl enable --now notify-images"
fi
if systemctl is-active --quiet notify-images 2>/dev/null; then
    pass "notify-images running"
else
    fail "notify-images running" "journalctl -u notify-images -n 20 --no-pager"
fi

NRESTART=$(systemctl show notify-images -p NRestarts --value 2>/dev/null)
if [ "${NRESTART:-0}" -gt 3 ]; then
    fail "notify-images stable" "$NRESTART restarts -- the script is exiting"
else
    pass "notify-images stable" "${NRESTART:-0} restarts"
fi

head_ "Hash manifest"

if systemctl is-enabled --quiet acq-hash 2>/dev/null; then
    pass "acq-hash enabled"
else
    fail "acq-hash enabled" "sudo systemctl enable --now acq-hash"
fi
if systemctl is-active --quiet acq-hash 2>/dev/null; then
    pass "acq-hash running"
else
    fail "acq-hash running" "journalctl -u acq-hash -n 20 --no-pager"
fi

if [ -f "$ACQ_MANIFEST" ]; then
    N=$(unhashed "$IMAGE_DIR" "$ACQ_MANIFEST")
    if [ "$N" -eq 0 ]; then
        pass "every image hashed" "$(wc -l < "$ACQ_MANIFEST") lines in $ACQ_MANIFEST"
    else
        fail "every image hashed" "$N older than 2 minutes not in $ACQ_MANIFEST. After downtime
                                   acq-hash is catching up; run this again in a few minutes."
    fi
else
    fail "every image hashed" "no $ACQ_MANIFEST. Re-run setup.sh."
fi

head_ "Retention"

RECORDS=$(dirname "$ACQ_MANIFEST")

if systemctl is-enabled --quiet reaper.timer 2>/dev/null; then
    pass "reaper.timer enabled"
else
    fail "reaper.timer enabled" "sudo systemctl enable --now reaper.timer"
fi
if systemctl is-active --quiet reaper.timer 2>/dev/null; then
    pass "reaper.timer waiting"
else
    fail "reaper.timer waiting" "systemctl status reaper.timer"
fi

# The reaper runs for seconds every 10 minutes, so its unit is inactive nearly
# always. Its last result is what shows whether it works.
if [ -z "$(systemctl show reaper -p ExecMainExitTimestamp --value 2>/dev/null)" ]; then
    skip "reaper last pass" "none yet; the first is 5 minutes after boot"
elif [ "$(systemctl show reaper -p Result --value 2>/dev/null)" = success ]; then
    pass "reaper last pass" "succeeded"
else
    fail "reaper last pass" "systemctl status reaper; journalctl -t reaper -n 20 --no-pager"
fi
LAST=$(journalctl -t reaper --since '-1 hour' -o cat --no-pager 2>/dev/null | grep '% used;' | tail -1)
[ -n "$LAST" ] && printf 'NOTE  %-34s %s\n' "reaper last summary" "$LAST"

if [ "$ON_LAN" -eq 0 ]; then
    skip "concordia manifest reachable" "not on the instrument LAN"
else
    FROM=""
    for ip in "$CONCORDIA1_IP" "$CONCORDIA2_IP"; do
        curl -s -f -I -m 5 "http://$ip:$HTTP_PORT/manifests/data.manifest" >/dev/null 2>&1 \
            && FROM="$FROM $ip"
    done
    if [ -n "$FROM" ]; then
        pass "concordia manifest reachable" "from$FROM"
    else
        fail "concordia manifest reachable" "no concordia answers, so no copy is verified and nothing is deleted"
    fi
fi

# A name recorded here is never deleted, so the image stays until its two
# copies are compared by hand.
NMIS=$(grep -c . "$RECORDS/mismatch.txt" 2>/dev/null || true)
if [ "${NMIS:-0}" -eq 0 ]; then
    pass "no hash mismatches"
else
    fail "no hash mismatches" "$NMIS in $RECORDS/mismatch.txt. Those images are kept;
                                   compare each with its copy on the concordia."
fi

# Deletion runs as user, which must be able to write each directory holding
# images, and IMAGE_DIR itself to remove one emptied.
NOWRITE=$(find "$IMAGE_DIR" -maxdepth 1 -type d ! -writable 2>/dev/null | wc -l)
if [ "$NOWRITE" -eq 0 ]; then
    pass "image directories writable by $(id -un)"
else
    fail "image directories writable by $(id -un)" "$NOWRITE are not, and the reaper cannot delete from them.
                                   find $IMAGE_DIR -maxdepth 1 -type d ! -writable"
fi

[ "${REAP_DRY_RUN:-1}" = 0 ] \
    || printf 'NOTE  %-34s %s\n' "reaper in dry run" "deletes nothing; lists what it would in $RECORDS/would-delete.txt"

# The reaper warns at each pass that leaves the disk above REAP_START_PCT.
PCT=$(df --output=pcent "$IMAGE_DIR" 2>/dev/null | tail -1 | tr -dc 0-9)
STILL=$(journalctl -t reaper --since '-30 min' -o cat --no-pager 2>/dev/null | grep '^still ' | tail -1)
if [ "${PCT:-0}" -lt "$REAP_START_PCT" ]; then
    pass "image disk" "${PCT}% used; the reaper starts at $REAP_START_PCT%"
elif [ "${REAP_DRY_RUN:-1}" != 0 ]; then
    fail "image disk" "${PCT}% used and the reaper is in dry run. Set REAP_DRY_RUN=0
                                   in site.conf and re-run setup.sh."
elif [ -n "$STILL" ]; then
    fail "image disk" "the reaper reports: $STILL"
else
    pass "image disk" "${PCT}% used; the reaper deletes down to $REAP_STOP_PCT% at its next pass"
fi

fi

# ======================================================== CONCORDIA ===========

if [ "${MACHINE_ROLE:-}" = data ]; then

head_ "Storage"

if mountpoint -q /data; then
    pass "/data is a mount point" "$(df -h /data | awk 'NR==2{print $2" total, "$4" free"}')"
else
    fail "/data is a mount point" "the archive may be on the root filesystem"
fi

for d in "$INCOMING_DIR" "$MANIFEST_DIR" "$LOCK_DIR"; do
    if [ -d "$d" ]; then
        if [ "$(stat -c %U "$d")" = user ]; then
            pass "$d" "owned by user"
        else
            fail "$d" "owned by $(stat -c %U "$d"), should be user"
        fi
    else
        fail "$d" "missing"
    fi
done

# LOCK_DIR is on tmpfs, and this entry recreates it at every boot.
if grep -q "^d $LOCK_DIR " /etc/tmpfiles.d/cryoscope.conf 2>/dev/null; then
    pass "$LOCK_DIR recreated at boot"
else
    fail "$LOCK_DIR recreated at boot" "not in /etc/tmpfiles.d/cryoscope.conf, so every transfer
                                   fails after the next reboot. Re-run setup.sh."
fi

# Take the lock the way the transfer paths do. A writable directory is not the
# property that matters, and testing it passed while every transfer was failing.
if flock -w 2 "$LOCK_DIR/pull.lock" true 2>/dev/null; then
    pass "transfer lock works"
else
    fail "transfer lock works" "no transfer path can run. Is $LOCK_DIR present?"
fi

# A unit stays active with zero restarts while its loop fails every pass, so
# unit state cannot show this. The journal can.
STUCK=$(journalctl -u pull-images --since '-15 min' --no-pager 2>/dev/null \
        | grep -c 'cannot open lock file' || true)
if [ "${STUCK:-0}" -gt 0 ]; then
    fail "pull-images transferring" "$STUCK lock failures in the last 15 minutes"
else
    pass "pull-images transferring"
fi

head_ "SSH to cryocontrol"

if [ "$ON_LAN" -eq 0 ]; then
    skip "SSH to cryocontrol" "not on the instrument LAN"
else
    if timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 cryocontrol true 2>/dev/null; then
        pass "non-interactive SSH works"
    else
        fail "non-interactive SSH works" "ssh cryocontrol true"
    fi
fi

for k in ServerAliveInterval ServerAliveCountMax ControlPersist; do
    if grep -qi "^[[:space:]]*$k" "$HOME/.ssh/config" 2>/dev/null; then
        pass "ssh config has $k"
    else
        fail "ssh config has $k" "a partition will strand rsync holding the lock"
    fi
done

# The identity actually in effect must exist on disk. If it does not, SSH is
# succeeding through a fallback.
EFF_KEY=$(ssh -G cryocontrol 2>/dev/null | awk '$1=="identityfile"{print $2}' | head -1)
EFF_KEY=${EFF_KEY/#\~/$HOME}
if [ -z "$EFF_KEY" ]; then
    fail "identity in effect" "ssh -G cryocontrol names no identity file"
elif [ -f "$EFF_KEY" ]; then
    pass "identity in effect" "$EFF_KEY"
else
    fail "identity in effect" "$EFF_KEY does not exist. SSH is working via a fallback."
fi

NBLOCK=$(grep -ci '^[[:space:]]*Host[[:space:]].*\bcryocontrol\b' "$HOME/.ssh/config" 2>/dev/null || true)
[ "${NBLOCK:-0}" -gt 1 ] && printf 'NOTE  %-34s %s\n' "Host cryocontrol blocks" \
    "$NBLOCK of them. First match wins per keyword; fold them into one."

head_ "Units"

CROLE=$(cat "$CONFDIR/role" 2>/dev/null || echo unknown)
case "$CROLE" in
    active) WANT_ON="pull-images trigger-pull nginx arrival-hash"; WANT_OFF="" ;;
    spare)  WANT_ON=""; WANT_OFF="pull-images trigger-pull nginx arrival-hash" ;;
    *)      WANT_ON=""; WANT_OFF="" ;;
esac

for u in $WANT_ON; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then pass "$u enabled"
    else fail "$u enabled" "role is $CROLE; run: role $CROLE"; fi
    if systemctl is-active --quiet "$u" 2>/dev/null; then pass "$u running"
    else fail "$u running" "journalctl -u $u -n 20 --no-pager"; fi
    n=$(systemctl show "$u" -p NRestarts --value 2>/dev/null)
    [ "${n:-0}" -gt 3 ] && fail "$u stable" "$n restarts -- the script is exiting" \
                        || pass "$u stable" "${n:-0} restarts"
done

for u in $WANT_OFF; do
    systemctl list-unit-files "$u*" --no-legend 2>/dev/null | grep -q . || continue
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then
        fail "$u disabled" "role is $CROLE but $u is enabled"
    else
        pass "$u disabled"
    fi
done

if crontab -l 2>/dev/null | grep -q 'pull-images-cron'; then
    if crontab -l 2>/dev/null | grep -q '^#SPARE .*pull-images-cron'; then
        if [ "$CROLE" = spare ]; then
            pass "hourly backstop" "disabled, correct for a spare"
        else
            fail "hourly backstop" "commented out, but this machine is $CROLE. Run: role active"
        fi
    else
        if [ "$CROLE" = spare ]; then
            fail "hourly backstop" "enabled on a spare. It would pull from cryocontrol hourly. Run: role spare"
        else
            pass "hourly backstop" "enabled"
        fi
    fi
else
    fail "hourly backstop in crontab" "the last line of defence is missing"
fi

# A nonzero count here means the fast path broke silently.
BACKSTOP=$(journalctl -t pull-images-cron --since "-25 hours" --no-pager 2>/dev/null \
           | grep -c 'to-check\|sending incremental' || true)
printf 'NOTE  %-34s %s\n' "backstop activity, 24h" "${BACKSTOP:-0} logged lines (nonzero means the fast path is missing files)"

head_ "Hash manifest"

if [ "$CROLE" = spare ]; then
    skip "every image hashed" "spare; arrival-hash runs on the active machine"
elif [ -f "$MANIFEST_DIR/data.manifest" ]; then
    N=$(unhashed "$INCOMING_DIR" "$MANIFEST_DIR/data.manifest")
    if [ "$N" -eq 0 ]; then
        pass "every image hashed" "$(wc -l < "$MANIFEST_DIR/data.manifest") lines in $MANIFEST_DIR/data.manifest"
    else
        fail "every image hashed" "$N older than 2 minutes not in $MANIFEST_DIR/data.manifest. After
                                   downtime arrival-hash is catching up; run this again in a few minutes."
    fi
else
    fail "every image hashed" "no $MANIFEST_DIR/data.manifest. journalctl -u arrival-hash -n 20 --no-pager"
fi

head_ "HTTP export"

if [ "$CROLE" = spare ]; then
    skip "nginx serving" "spare; nothing points here until failover"
else
    if curl -s -f -m 5 "http://$MY_IP:$HTTP_PORT/" >/dev/null 2>&1; then
        pass "nginx serving on $MY_IP:$HTTP_PORT"
    else
        fail "nginx serving on $MY_IP:$HTTP_PORT" "curl -v http://$MY_IP:$HTTP_PORT/"
    fi

    # The sweep reads the listing with this pattern (eavesdropper/sweep.sh).
    # Every entry must match it, or the sweep skips that entry without a word.
    LISTING=$(curl -s -m 5 "http://$MY_IP:$HTTP_PORT/" 2>/dev/null)
    NENTRY=$(printf '%s' "$LISTING" | grep -o '"name":' | wc -l)
    NPARSE=$(printf '%s' "$LISTING" | grep -o '"name":"[^"]*", *"type":"[^"]*"' | wc -l)
    if [ "${LISTING:0:1}" = "[" ] && [ "$NENTRY" -eq "$NPARSE" ]; then
        pass "autoindex is JSON" "$NPARSE of $NENTRY entries parse as the sweep reads them"
    else
        fail "autoindex is JSON" "$NPARSE of $NENTRY entries parse; the reconciliation sweep reads this"
    fi

    # Without the space in "location ~ /\." this returns 200 and staging
    # files are exposed.
    CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
           "http://$MY_IP:$HTTP_PORT/.rsync-tmp/" 2>/dev/null)
    if [ "$CODE" = "403" ]; then
        pass "dotted paths denied" "403"
    else
        fail "dotted paths denied" "got $CODE, expected 403. Staging files are exposed."
    fi

    if curl -s -o /dev/null -m 5 -w '%{http_code}' -X PUT \
         "http://$MY_IP:$HTTP_PORT/probe" 2>/dev/null | grep -q '^40'; then
        pass "export is read-only"
    else
        fail "export is read-only" "limit_except is not taking effect"
    fi

    # cryocontrol deletes an image only when this manifest shows a matching copy.
    if curl -s -f -I -m 5 "http://$MY_IP:$HTTP_PORT/manifests/data.manifest" >/dev/null 2>&1; then
        pass "manifest served" "/manifests/data.manifest"
    else
        fail "manifest served" "cryocontrol verifies nothing and deletes nothing.
                                   curl -I http://$MY_IP:$HTTP_PORT/manifests/data.manifest"
    fi

    if curl -s -o /dev/null -m 5 -w '%{http_code}' -X PUT \
         "http://$MY_IP:$HTTP_PORT/manifests/probe" 2>/dev/null | grep -q '^40'; then
        pass "manifest is read-only"
    else
        fail "manifest is read-only" "limit_except is not taking effect on /manifests/"
    fi
fi

head_ "Firewall"

if sudo -n iptables -S INPUT 2>/dev/null | grep -q -- '--comment cryoscope'; then
    NRULES=$(sudo -n iptables -S INPUT 2>/dev/null | grep -c -- '--comment cryoscope')
    pass "port $HTTP_PORT rules present" "$NRULES rules"
    if sudo -n iptables -S INPUT 2>/dev/null | grep -- '--comment cryoscope' | tail -1 | grep -q DROP; then
        pass "drop rule is last"
    else
        fail "drop rule is last" "accepts must precede the drop; re-run setup.sh"
    fi
else
    skip "port $HTTP_PORT rules present" "needs passwordless sudo to read; check by hand"
fi

if [ -n "${EAVESDROPPERS:-}" ]; then
    EMISSING=""
    for a in $EAVESDROPPERS; do
        sudo -n iptables -S INPUT 2>/dev/null | grep -q -- "-s $a/32 .*--comment cryoscope" \
            || EMISSING="$EMISSING $a"
    done
    if sudo -n iptables -S INPUT >/dev/null 2>&1; then
        [ -z "$EMISSING" ] && pass "eavesdroppers in the allow list" "$EAVESDROPPERS" \
                           || fail "eavesdroppers in the allow list" "missing:$EMISSING. Re-run setup.sh."
    else
        skip "eavesdroppers in the allow list" "needs passwordless sudo to read; configured: $EAVESDROPPERS"
    fi
else
    skip "eavesdroppers in the allow list" "EAVESDROPPERS is empty"
fi

fi

# ------------------------------------------------------- multicast and time --

head_ "Multicast"

if [ "$ON_LAN" -eq 0 ]; then
    skip "multicast round trip" "not on the instrument LAN"
elif ! command -v socat >/dev/null; then
    skip "multicast round trip" "socat not installed on this machine"
else
    OUT=$(mktemp)
    timeout 6 socat -u "UDP4-RECV:$MCAST_PORT,ip-add-membership=$MCAST_GROUP:$IFACE,reuseaddr" \
        - > "$OUT" 2>"$OUT.err" &
    SPID=$!
    sleep 1
    if grep -qi 'no such device' "$OUT.err" 2>/dev/null; then
        fail "multicast join" "socat was given something that is not a local interface.
                                   ip-add-membership takes an interface NAME, not an address."
    else
        printf 'CHECK_PROBE %s %s\n' "$HOST" "$(date +%s.%3N)" \
            > "/dev/udp/$MCAST_GROUP/$MCAST_PORT" 2>/dev/null
        sleep 2
        if grep -q CHECK_PROBE "$OUT" 2>/dev/null; then
            pass "multicast loopback" "sent and received on $IFACE"
        else
            fail "multicast loopback" "nothing came back. Check the firewall before the network."
        fi
        # Other traffic on the group in this window is the live system.
        if grep -q 'IMAGE_COMPLETE\|IMAGE_AVAILABLE' "$OUT" 2>/dev/null; then
            printf 'NOTE  %-34s %s\n' "live traffic seen" "$(grep -c 'IMAGE_' "$OUT") datagram(s) during the check"
        fi
    fi
    kill $SPID 2>/dev/null
    wait $SPID 2>/dev/null
    rm -f "$OUT" "$OUT.err"
fi

# ------------------------------------------------------------ transfer test --

head_ "Timed transfer test"

if [ "$DO_TRANSFER" -eq 0 ]; then
    skip "rename to arrival" "not run. Add --transfer to include it."
elif [ "${MACHINE_ROLE:-}" != data ]; then
    skip "rename to arrival" "run this from a concordia, not from cryocontrol"
elif [ "$ON_LAN" -eq 0 ]; then
    skip "rename to arrival" "not on the instrument LAN"
elif [ "$CROLE" != active ]; then
    skip "rename to arrival" "this machine is $CROLE; the active machine does the pulling"
else
    # The camera writes into a dated subdirectory, so the test must exercise
    # that path rather than the image root, which nothing renames into.
    T=$(date +%Y%m%d)/zz_check_$$.fits
    START=$(date +%s.%3N)
    if ssh -o BatchMode=yes -o ConnectTimeout=5 cryocontrol \
        "mkdir -p $IMAGE_DIR/$(date +%Y%m%d) && touch $IMAGE_DIR/$T.writing && mv $IMAGE_DIR/$T.writing $IMAGE_DIR/$T" 2>/dev/null; then
        ARRIVED=0
        for _ in $(seq 1 40); do
            [ -f "$INCOMING_DIR/$T" ] && { ARRIVED=1; break; }
            sleep 0.25
        done
        END=$(date +%s.%3N)
        EL=$(awk -v a="$END" -v b="$START" 'BEGIN{printf "%.3f", a-b}')
        if [ "$ARRIVED" -eq 1 ]; then
            pass "rename to arrival" "$EL s"
            # Under about a second is the trigger. Around 3 s is the polling
            # floor, which means the trigger is dead.
            awk -v e="$EL" 'BEGIN{exit !(e > 1.5)}' \
                && printf 'NOTE  %-34s %s\n' "path used" "slow: the 3 s poll, not the trigger. Check notify-images on cryocontrol." \
                || printf 'NOTE  %-34s %s\n' "path used" "trigger"
        else
            fail "rename to arrival" "nothing arrived in 10 s"
        fi
        ssh -o BatchMode=yes cryocontrol "rm -f $IMAGE_DIR/$T" 2>/dev/null
        rm -f "$INCOMING_DIR/$T"
    else
        fail "rename to arrival" "could not create the test file on cryocontrol"
    fi
fi

# ---------------------------------------------------------------- summary ----

printf '\n================================================================\n'
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -eq 0 ]; then
    printf 'This machine is correct for its role.\n'
fi
printf '================================================================\n'

[ "$FAIL" -eq 0 ] || exit 1
exit 0
