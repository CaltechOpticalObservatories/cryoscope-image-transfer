#!/bin/bash
#
# setup.sh -- install and configure one Cryoscope machine.
#
# Run from the directory holding site.conf, role and check.sh, with the
# programs and unit files it installs in bin/ and units/ beside them.
#
# Installs the transfer layer and the notification layer.

set -u
umask 022

CONFDIR=/etc/cryoscope
CONFFILE=site.conf
CONF=$CONFDIR/$CONFFILE
MACHINE_CONF=$CONFDIR/machine.conf
ROLE_FILE=$CONFDIR/role
SRCDIR=$(cd "$(dirname "$0")" && pwd)

CHANGED_UNITS=""
DEFERRED=0
FAILURES=0

# ---------------------------------------------------------------- reporting --

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok       %s\n' "$*"; }
note() { printf '   note     %s\n' "$*"; }
warn() { printf '   WARNING  %s\n' "$*"; }
defer(){ printf '   DEFERRED %s\n' "$*"; DEFERRED=1; }
die()  { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

mark_changed() {
    case " $CHANGED_UNITS " in
        *" $1 "*) ;;
        *) CHANGED_UNITS="$CHANGED_UNITS $1" ;;
    esac
}

# install_file MODE PATH [OWNER] -- write stdin only if the content differs.
# Returns 0 if the file changed, 1 if it did not.
install_file() {
    local mode=$1 path=$2 owner=${3:-} tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    sudo install -D -m "$mode" ${owner:+-o "${owner%%:*}" -g "${owner##*:}"} \
        "$tmp" "$path" || die "could not write $path"
    rm -f "$tmp"
    return 0
}

# install_src MODE NAME PATH -- install_file from $SRCDIR/NAME. A missing source
# would otherwise fail the redirect and be reported as unchanged.
install_src() {
    [ -s "$SRCDIR/$2" ] || die "$2 is missing or empty in $SRCDIR.
       Copy the whole image-transfer directory and run setup.sh from there."
    install_file "$1" "$3" < "$SRCDIR/$2"
}

# ------------------------------------------------------------ preconditions --

step "Preconditions"

[ "$(id -u)" -ne 0 ] || die "run this as the account 'user', not as root. It uses sudo itself."
[ "$(id -un)" = user ] || die "this must run as the account 'user'; you are $(id -un)."
sudo -n true 2>/dev/null || sudo true || die "user needs sudo rights."
ok "running as user with sudo"

HOST=$(hostname)
case "$HOST" in
    cryocontrol) MACHINE_ROLE=emitter ;;
    concordia1)  MACHINE_ROLE=data ;;
    concordia2)  MACHINE_ROLE=data ;;
    *) die "unrecognised hostname '$HOST'.
       This machine must be named cryocontrol, concordia1 or concordia2 before
       setup.sh will run. setup.sh does not set the hostname.
           sudo hostnamectl set-hostname NAME
       Then log out, log in, and run setup.sh again." ;;
esac
ok "hostname $HOST, machine role $MACHINE_ROLE"

command -v ip >/dev/null || die "iproute2 is missing."

# setup.sh installs the other files from its own directory, so it cannot be
# run from the destination.
if [ "$SRCDIR" = /usr/local/bin ] || [ "$SRCDIR" = /usr/bin ]; then
    die "setup.sh is being run from $SRCDIR.
       It is not meant to be installed. It installs role and check.sh from its
       own directory, so running it from the destination cannot work.
           sudo rm $SRCDIR/setup.sh
           cd ~/Software/image-transfer && ./setup.sh"
fi
for f in $CONFFILE role check.sh; do
    [ -f "$SRCDIR/$f" ] || die "$f is not in $SRCDIR, beside setup.sh.
       Copy the whole image-transfer directory and run setup.sh from there."
done
ok "$CONFFILE, role and check.sh found beside setup.sh"

# Exactly one global-scope interface. If there is more than one, fall back to
# the interface recorded on a previous run rather than guessing.
IFACE_LIST=$(ip -4 -o addr show scope global | awk '{print $2}' | sort -u)
IFACE_COUNT=$(printf '%s\n' "$IFACE_LIST" | grep -c .)
IFACE=""
if [ "$IFACE_COUNT" -eq 1 ]; then
    IFACE=$IFACE_LIST
elif [ "$IFACE_COUNT" -eq 0 ]; then
    die "no global-scope IPv4 interface found. Configure the LAN address first."
else
    if [ -f "$MACHINE_CONF" ]; then
        RECORDED=$(awk -F= '$1=="IFACE"{print $2}' "$MACHINE_CONF")
        if [ -n "$RECORDED" ] && ip link show "$RECORDED" >/dev/null 2>&1; then
            IFACE=$RECORDED
            note "more than one global-scope interface; using $IFACE as recorded
            in $MACHINE_CONF."
        fi
    fi
    [ -n "$IFACE" ] || die "more than one global-scope interface, and setup.sh will not guess:
$(printf '%s\n' "$IFACE_LIST" | sed 's/^/           /')
       Leave exactly one on the instrument LAN, or set IFACE in
       $MACHINE_CONF and re-run:
           printf 'IFACE=NAME\\n' | sudo tee -a $MACHINE_CONF"
fi
MY_IP=$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$MY_IP" ] || die "$IFACE has no global-scope IPv4 address."
ok "interface $IFACE, address $MY_IP"

ip link show "$IFACE" | head -1 | grep -q MULTICAST \
    || die "interface $IFACE does not have the MULTICAST flag.
       sudo ip link set $IFACE multicast on"
ok "$IFACE is multicast capable"

bash -c 'exec 3<>/dev/udp/127.0.0.1/9' 2>/dev/null \
    || die "this bash has no /dev/udp support. The trigger cannot work without it."
ok "bash supports /dev/udp"

# ------------------------------------------------------------ address table --

step "Address table"

# The source tree is authoritative, as it is for role and check.sh. An
# installed copy that differs is replaced, and kept as a timestamped backup so
# a hand-edit made in /etc is never lost silently.
if [ ! -f "$CONF" ]; then
    sudo install -D -m 644 "$SRCDIR/$CONFFILE" "$CONF" || die "could not install $CONF"
    ok "installed $CONF from $SRCDIR/$CONFFILE"
elif cmp -s "$SRCDIR/$CONFFILE" "$CONF"; then
    ok "$CONF matches $SRCDIR/$CONFFILE"
else
    CONF_BAK="$CONF.$(date +%Y%m%d-%H%M%S).bak"
    sudo cp -p "$CONF" "$CONF_BAK" || die "could not back up $CONF"
    sudo install -D -m 644 "$SRCDIR/$CONFFILE" "$CONF" || die "could not install $CONF"
    ok "replaced $CONF from $SRCDIR/$CONFFILE"
    note "the installed copy differed and was kept as
            $CONF_BAK
            Compare with: diff $CONF_BAK $CONF"
fi

# shellcheck source=/dev/null
. "$CONF"

for v in CRYOCONTROL_IP CONCORDIA1_IP CONCORDIA2_IP MCAST_GROUP MCAST_PORT \
         HTTP_PORT IMAGE_DIR INCOMING_DIR MANIFEST_DIR LOCK_DIR ACQ_MANIFEST \
         REAP_DRY_RUN REAP_START_PCT REAP_STOP_PCT REAP_MIN_AGE_HOURS REAP_KEEP_NEWEST; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "$v is empty in $CONF."
done
for v in REAP_START_PCT REAP_STOP_PCT REAP_MIN_AGE_HOURS REAP_KEEP_NEWEST; do
    eval "val=\$$v"
    case "$val" in *[!0-9]*) die "$v=$val in $CONF is not a whole number." ;; esac
done
[ "$REAP_STOP_PCT" -lt "$REAP_START_PCT" ] \
    || die "REAP_STOP_PCT ($REAP_STOP_PCT) must be below REAP_START_PCT ($REAP_START_PCT) in $CONF."
ok "address table complete"

if [ -n "${EAVESDROPPERS:-}" ]; then
    ok "eavesdroppers: $EAVESDROPPERS"
else
    note "EAVESDROPPERS is empty. Nothing outside the three instrument machines
            may fetch over port $HTTP_PORT."
fi

# Is this machine at the address the table claims for it? On the cryocontrol
# cold spare it is not, and that is expected rather than an error.
case "$HOST" in
    cryocontrol) EXPECT_IP=$CRYOCONTROL_IP ;;
    concordia1)  EXPECT_IP=$CONCORDIA1_IP ;;
    concordia2)  EXPECT_IP=$CONCORDIA2_IP ;;
esac

ON_LAN=1
if [ "$MY_IP" != "$EXPECT_IP" ]; then
    ON_LAN=0
    if [ "$HOST" = cryocontrol ]; then
        defer "this machine is at $MY_IP, the table says cryocontrol is $EXPECT_IP.
            Treating it as the cold spare. Everything is installed; nothing that
            needs the instrument LAN is verified. This is not a failure."
    else
        warn "this machine is at $MY_IP but the table says $HOST is $EXPECT_IP.
            Installing anyway. Fix the address or the table before relying on it."
    fi
else
    ok "address matches the table"
fi

# -------------------------------------------------------------- per-machine --

step "Per-machine configuration"

install_file 644 "$MACHINE_CONF" <<EOF
# /etc/cryoscope/machine.conf
# Generated by setup.sh. Per-machine values that differ between hosts.
# The interface name differs per machine and is derived, never hardcoded.
IFACE=$IFACE
MY_IP=$MY_IP
MACHINE_ROLE=$MACHINE_ROLE
EOF
[ $? -eq 0 ] && ok "wrote $MACHINE_CONF" || ok "$MACHINE_CONF unchanged"

# ------------------------------------------------------------------- /etc/hosts --

step "Name resolution (/etc/hosts)"

HOSTS_BLOCK=$(cat <<EOF
# BEGIN cryoscope -- generated by setup.sh from $CONF. Do not edit by hand.
$CRYOCONTROL_IP  cryocontrol
$CONCORDIA1_IP   concordia1
$CONCORDIA2_IP   concordia2
# END cryoscope
EOF
)

# setup.sh owns the mapping for these three names. An entry for any of them
# outside the block wins, because getent returns the first match, so a stale
# line silently overrides the table. Loopback lines are left alone: Debian's
# 127.0.1.1 entry for this machine's own name is legitimate.
STALE=$(sed '/^# BEGIN cryoscope/,/^# END cryoscope/d' /etc/hosts \
        | grep -vE '^[[:space:]]*(#|$)' \
        | grep -vE '^[[:space:]]*127\.' \
        | grep -E '[[:space:]](cryocontrol|concordia1|concordia2)([[:space:]]|$)' || true)

CURRENT_BLOCK=$(sed -n '/^# BEGIN cryoscope/,/^# END cryoscope/p' /etc/hosts)
if [ "$CURRENT_BLOCK" = "$HOSTS_BLOCK" ] && [ -z "$STALE" ]; then
    ok "/etc/hosts block current"
else
    tmp=$(mktemp)
    sed '/^# BEGIN cryoscope/,/^# END cryoscope/d' /etc/hosts > "$tmp"
    if [ -n "$STALE" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            esc=$(printf '%s' "$line" | sed 's/[][\.*^$\/&]/\\&/g')
            sed -i "/^$esc$/d" "$tmp"
        done <<< "$STALE"
    fi
    printf '%s\n' "$HOSTS_BLOCK" >> "$tmp"
    sudo install -m 644 "$tmp" /etc/hosts || die "could not write /etc/hosts"
    rm -f "$tmp"
    ok "/etc/hosts block written"
    if [ -n "$STALE" ]; then
        note "removed $(printf '%s\n' "$STALE" | grep -c .) stale entry(ies) that
            overrode the address table:"
        printf '%s\n' "$STALE" | sed 's/^/               /'
    fi
fi

# Resolving is not enough; it must resolve to the address in the table.
for n in cryocontrol concordia1 concordia2; do
    case "$n" in
        cryocontrol) want=$CRYOCONTROL_IP ;;
        concordia1)  want=$CONCORDIA1_IP ;;
        concordia2)  want=$CONCORDIA2_IP ;;
    esac
    got=$(getent hosts "$n" 2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$got" ] || die "$n does not resolve after writing /etc/hosts."
    if [ "$got" != "$want" ]; then
        # Debian's 127.0.1.1 line answers first for this machine's own name.
        # Harmless: peers resolve it from their own hosts file.
        if [ "$n" = "$HOST" ] && [ "$got" = "127.0.1.1" ]; then
            continue
        fi
        die "$n resolves to $got, but the table says $want.
       Something in /etc/hosts, or a name service, overrides the table."
    fi
done
ok "cryocontrol, concordia1, concordia2 resolve to the table addresses"

# ---------------------------------------------------------------- packages --

step "Packages"

case "$MACHINE_ROLE" in
    emitter) PKGS="inotify-tools openssh-server rsync curl coreutils socat" ;;
    data)    PKGS="rsync openssh-client openssh-server util-linux socat nginx cron curl iptables-persistent coreutils" ;;
esac

MISSING=""
for p in $PKGS; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || MISSING="$MISSING $p"
done

if [ -n "$MISSING" ]; then
    say "   installing:$MISSING"
    # iptables-persistent prompts unless told not to.
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | sudo debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | sudo debconf-set-selections

    # apt-get update exits nonzero if any repository fails, including ones
    # unrelated to this system. Warn and install from the cached lists.
    UPD=$(sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1)
    if [ -n "$UPD" ]; then
        BADREPO=$(printf '%s\n' "$UPD" | sed -n "s/.*The repository '\([^ ]*\).*/\1/p" | head -1)
        warn "apt-get update reported errors. Continuing with the cached lists."
        printf '%s\n' "$UPD" | sed 's/^/            /'
        [ -n "$BADREPO" ] && say "            If $BADREPO is not needed on this machine, disable it:
              grep -rl \"\$(echo $BADREPO | awk -F/ '{print \$3}')\" /etc/apt/sources.list /etc/apt/sources.list.d/
              sudo mv THAT_FILE THAT_FILE.disabled"
    fi

    # shellcheck disable=SC2086
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $MISSING; then
        ok "installed:$MISSING"
    else
        die "package installation failed:$MISSING
       If apt-get update reported a broken repository above, disable that
       repository and re-run setup.sh. It is almost certainly unrelated to
       this system."
    fi
else
    ok "all packages present"
fi

# ================================================================ CRYOCONTROL ==

if [ "$MACHINE_ROLE" = emitter ]; then

step "Image directory"

if [ -d "$IMAGE_DIR" ]; then
    ok "$IMAGE_DIR exists"
else
    sudo install -d -o user -g user -m 755 "$IMAGE_DIR" || die "could not create $IMAGE_DIR"
    ok "created $IMAGE_DIR"
fi
[ -r "$IMAGE_DIR" ] || die "$IMAGE_DIR is not readable by user."

step "Notification emitter"

if install_src 755 bin/notify-images.sh /usr/local/bin/notify-images.sh
then ok "wrote /usr/local/bin/notify-images.sh"; mark_changed notify-images
else ok "notify-images.sh unchanged"; fi

if install_src 644 units/notify-images.service /etc/systemd/system/notify-images.service
then ok "wrote notify-images.service"; mark_changed notify-images
else ok "notify-images.service unchanged"; fi

step "Hash manifest"

ACQ_DIR=$(dirname "$ACQ_MANIFEST")
if [ -d "$ACQ_DIR" ]; then
    ok "$ACQ_DIR exists"
else
    sudo install -d -o user -g user -m 755 "$ACQ_DIR" || die "could not create $ACQ_DIR"
    ok "created $ACQ_DIR"
fi
[ -w "$ACQ_DIR" ] || die "$ACQ_DIR is not writable by user."

if install_src 755 bin/acq-hash.sh /usr/local/bin/acq-hash.sh
then ok "wrote /usr/local/bin/acq-hash.sh"; mark_changed acq-hash
else ok "acq-hash.sh unchanged"; fi

if install_src 644 units/acq-hash.service /etc/systemd/system/acq-hash.service
then ok "wrote acq-hash.service"; mark_changed acq-hash
else ok "acq-hash.service unchanged"; fi

step "Reaper"

if install_src 755 bin/reaper.sh /usr/local/bin/reaper.sh
then ok "wrote /usr/local/bin/reaper.sh"
else ok "reaper.sh unchanged"; fi

if install_src 644 units/reaper.service /etc/systemd/system/reaper.service
then ok "wrote reaper.service"
else ok "reaper.service unchanged"; fi

if install_src 644 units/reaper.timer /etc/systemd/system/reaper.timer
then ok "wrote reaper.timer"; mark_changed reaper.timer
else ok "reaper.timer unchanged"; fi

if [ "$REAP_DRY_RUN" = 0 ]; then
    ok "reaper deletes verified images from $REAP_START_PCT% used down to $REAP_STOP_PCT%"
else
    note "reaper is in dry run (REAP_DRY_RUN=$REAP_DRY_RUN) and deletes nothing.
            It lists what it would delete in $(dirname "$ACQ_MANIFEST")/would-delete.txt."
fi

fi

# ================================================================== CONCORDIA ==

if [ "$MACHINE_ROLE" = data ]; then

step "Storage"

if mountpoint -q /data; then
    ok "/data is a mount point"
else
    warn "/data is NOT a mount point. If the storage array is not mounted, the
            archive is being written to the root filesystem. Verify with
            'df -h $INCOMING_DIR' before trusting this machine."
fi

for d in "$INCOMING_DIR" "$MANIFEST_DIR"; do
    if [ -d "$d" ]; then
        ok "$d exists"
    else
        sudo install -d -o user -g user -m 755 "$d" || die "could not create $d"
        ok "created $d"
    fi
    [ "$(stat -c %U "$d")" = user ] || sudo chown user:user "$d"
done

# LOCK_DIR is under /var/lock, which is tmpfs and is wiped at every boot. All
# three transfer paths -- the polling loop, the trigger and the hourly cron --
# take a lock inside it, so if it is missing every transfer fails while every
# unit still reports healthy. Creating it here would not survive a reboot, so
# it is declared to systemd-tmpfiles, which recreates it at each boot before
# any service starts.
if install_file 644 /etc/tmpfiles.d/cryoscope.conf <<EOF
# Generated by setup.sh from $CONF. Do not edit by hand.
# $LOCK_DIR is on tmpfs; without this it vanishes at boot and every
# transfer path fails silently.
d $LOCK_DIR 0755 user user -
EOF
then ok "wrote /etc/tmpfiles.d/cryoscope.conf"
else ok "tmpfiles.d entry unchanged"; fi

sudo systemd-tmpfiles --create /etc/tmpfiles.d/cryoscope.conf \
    || die "systemd-tmpfiles could not create $LOCK_DIR"
[ -d "$LOCK_DIR" ] || die "$LOCK_DIR still missing after systemd-tmpfiles."
ok "$LOCK_DIR present, and recreated at every boot"

if flock -w 2 "$LOCK_DIR/pull.lock" true 2>/dev/null; then
    ok "transfer lock works"
else
    die "cannot take the lock at $LOCK_DIR/pull.lock. Every transfer path
       would fail while every unit reported healthy."
fi

step "SSH to cryocontrol"

install -d -m 700 "$HOME/.ssh"
touch "$HOME/.ssh/config"

# Take the identity already in effect for cryocontrol, before the config is
# rewritten. Generate one only if no usable identity exists.
SSH_KEY=""
while read -r f; do
    f=${f/#\~/$HOME}
    [ -f "$f" ] && { SSH_KEY=$f; break; }
done <<< "$(ssh -G cryocontrol 2>/dev/null | awk '$1=="identityfile"{print $2}')"

# ssh takes the first value it sees for each keyword, so a Host cryocontrol
# block outside our markers wins where the two overlap.
PRE_BLOCK=$(sed '/^# BEGIN cryoscope/,/^# END cryoscope/d' "$HOME/.ssh/config" \
            | grep -ci '^[[:space:]]*Host[[:space:]].*\bcryocontrol\b' || true)

if [ -n "$SSH_KEY" ]; then
    ok "using the identity already configured: $SSH_KEY"
else
    if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q \
            || die "ssh-keygen failed."
        ok "generated $HOME/.ssh/id_ed25519 (empty passphrase, required by systemd)"
        note "install this public key on cryocontrol before the transfer will work:"
        say ""
        say "   $(cat "$HOME/.ssh/id_ed25519.pub")"
        say ""
    fi
    SSH_KEY=$HOME/.ssh/id_ed25519
    ok "using $SSH_KEY"
fi

# Manage only our own block in ~/.ssh/config, leaving anything else alone.
SSH_BLOCK=$(cat <<EOF
# BEGIN cryoscope -- generated by setup.sh. Do not edit by hand.
Host cryocontrol
    HostName cryocontrol
    User user
    IdentityFile $SSH_KEY
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
    ServerAliveInterval 15
    ServerAliveCountMax 3
# END cryoscope
EOF
)
CURRENT_SSH=$(sed -n '/^# BEGIN cryoscope/,/^# END cryoscope/p' "$HOME/.ssh/config")
if [ "$CURRENT_SSH" = "$SSH_BLOCK" ]; then
    ok "~/.ssh/config block current"
else
    tmp=$(mktemp)
    sed '/^# BEGIN cryoscope/,/^# END cryoscope/d' "$HOME/.ssh/config" > "$tmp"
    printf '%s\n' "$SSH_BLOCK" >> "$tmp"
    install -m 600 "$tmp" "$HOME/.ssh/config"
    rm -f "$tmp"
    ok "wrote ~/.ssh/config block"
    note "ServerAliveInterval and ServerAliveCountMax are load-bearing: without
            them a partition strands rsync holding the lock."
fi

if [ "${PRE_BLOCK:-0}" -gt 0 ]; then
    note "a Host cryocontrol block also exists outside our markers. ssh takes
            the first value per keyword, so that block wins where the two
            overlap. Worth folding into one."
fi

# Seed known_hosts so the first connection never prompts.
if [ "$ON_LAN" -eq 1 ]; then
    if ! ssh-keygen -F cryocontrol -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
        if ssh-keyscan -T 5 -H cryocontrol >> "$HOME/.ssh/known_hosts" 2>/dev/null; then
            ok "seeded cryocontrol host key"
        else
            warn "could not reach cryocontrol to seed its host key."
        fi
    else
        ok "cryocontrol host key already known"
    fi

    if ssh -o BatchMode=yes -o ConnectTimeout=5 cryocontrol true 2>/dev/null; then
        ok "non-interactive SSH to cryocontrol works"
    else
        warn "SSH to cryocontrol failed. Nothing will transfer until it works.
            Install this machine's public key on cryocontrol:
              ssh-copy-id -i ${SSH_KEY}.pub cryocontrol"
        FAILURES=$((FAILURES+1))
    fi
else
    defer "SSH to cryocontrol not verified"
fi

step "Transfer"

if install_src 755 bin/pull-images.sh /usr/local/bin/pull-images.sh
then ok "wrote /usr/local/bin/pull-images.sh"; mark_changed pull-images
else ok "pull-images.sh unchanged"; fi

if install_src 644 units/pull-images.service /etc/systemd/system/pull-images.service
then ok "wrote pull-images.service"; mark_changed pull-images
else ok "pull-images.service unchanged"; fi

step "Triggered pull"

if install_src 755 bin/trigger-pull.sh /usr/local/bin/trigger-pull.sh
then ok "wrote /usr/local/bin/trigger-pull.sh"; mark_changed trigger-pull
else ok "trigger-pull.sh unchanged"; fi

if install_src 644 units/trigger-pull.service /etc/systemd/system/trigger-pull.service
then ok "wrote trigger-pull.service"; mark_changed trigger-pull
else ok "trigger-pull.service unchanged"; fi

step "Hash manifest"

# Enabled by role on the active machine, not here.
if install_src 755 bin/arrival-hash.sh /usr/local/bin/arrival-hash.sh
then ok "wrote /usr/local/bin/arrival-hash.sh"; mark_changed arrival-hash
else ok "arrival-hash.sh unchanged"; fi

if install_src 644 units/arrival-hash.service /etc/systemd/system/arrival-hash.service
then ok "wrote arrival-hash.service"; mark_changed arrival-hash
else ok "arrival-hash.service unchanged"; fi

step "Hourly backstop"

# setup.sh creates this line and keeps its command text current. Whether it is
# enabled belongs to the role, so an existing "#SPARE " prefix is preserved.
CRON_CMD="17 * * * * flock -n $LOCK_DIR/pull.lock rsync -a --partial-dir=.rsync-tmp --exclude='*.writing' cryocontrol:$IMAGE_DIR/ $INCOMING_DIR/ 2>&1 | logger -t pull-images-cron"
CRON_CUR=$(crontab -l 2>/dev/null || true)
CRON_LINE=$(printf '%s\n' "$CRON_CUR" | grep 'pull-images-cron' | head -1)
CRON_PREFIX=""
case "$CRON_LINE" in "#SPARE "*) CRON_PREFIX="#SPARE " ;; esac
CRON_WANT="${CRON_PREFIX}${CRON_CMD}"

if [ "$CRON_LINE" = "$CRON_WANT" ]; then
    ok "minute 17 backstop present${CRON_PREFIX:+, disabled for the spare role}"
else
    CRON_NEW=$( { printf '%s\n' "$CRON_CUR" | grep -v 'pull-images-cron'; \
                  printf '%s\n' "$CRON_WANT"; } | grep -v '^$')
    printf '%s\n' "$CRON_NEW" | crontab - || die "could not install crontab."
    if [ -z "$CRON_LINE" ]; then
        ok "installed minute 17 backstop"
    else
        ok "updated minute 17 backstop${CRON_PREFIX:+, still disabled for the spare role}"
    fi
fi

step "HTTP export"

if install_file 644 /etc/nginx/sites-available/incoming <<EOF
# Generated by setup.sh from $CONF. Do not edit by hand.
#
# listen takes a literal address; a name is resolved at config-parse time and
# creates an ordering dependency on /etc/hosts.
server {
    listen $MY_IP:$HTTP_PORT;
    root $INCOMING_DIR;

    # The space in "location ~ /\\." is required. Without it the block never
    # matches and nginx -t still passes.
    location ~ /\\. {
        deny all;
    }

    location / {
        autoindex on;
        autoindex_format json;
        # limit_except is valid only inside a location block.
        limit_except GET HEAD { deny all; }
    }

    # data.manifest, fetched by cryocontrol to check each copy before it deletes
    # the original. Outside root, so it never appears in the listing the sweep
    # reads.
    location /manifests/ {
        alias $MANIFEST_DIR/;
        limit_except GET HEAD { deny all; }
    }
}
EOF
then ok "wrote nginx site"; mark_changed nginx
else ok "nginx site unchanged"; fi

if [ -L /etc/nginx/sites-enabled/incoming ]; then
    ok "nginx site enabled"
else
    sudo ln -sf /etc/nginx/sites-available/incoming /etc/nginx/sites-enabled/incoming
    ok "enabled nginx site"
    mark_changed nginx
fi
if [ -e /etc/nginx/sites-enabled/default ]; then
    sudo rm -f /etc/nginx/sites-enabled/default
    ok "removed nginx default site"
    mark_changed nginx
fi
sudo nginx -t 2>/dev/null || die "nginx configuration is invalid. Nothing was restarted."
ok "nginx configuration valid"

step "Firewall"

# Rebuilt in order every run. The accepts must precede the drop.
sudo iptables -S INPUT | grep -- '--comment cryoscope' | sed 's/^-A/-D/' \
    | while read -r rule; do
        # shellcheck disable=SC2086
        sudo iptables $rule 2>/dev/null
      done

# The three instrument machines always; every eavesdropper in the list.
ALLOW="$CRYOCONTROL_IP $CONCORDIA1_IP $CONCORDIA2_IP ${EAVESDROPPERS:-}"

sudo iptables -A INPUT -p udp --dport "$MCAST_PORT" \
    -m comment --comment cryoscope -j ACCEPT
for a in $ALLOW; do
    sudo iptables -A INPUT -p tcp --dport "$HTTP_PORT" -s "$a" \
        -m comment --comment cryoscope -j ACCEPT
done
sudo iptables -A INPUT -p tcp --dport "$HTTP_PORT" \
    -m comment --comment cryoscope -j DROP
ok "port $HTTP_PORT restricted to:$ALLOW"

if sudo netfilter-persistent save >/dev/null 2>&1; then
    ok "firewall rules persisted"
else
    warn "could not persist firewall rules. They will be lost at reboot."
    FAILURES=$((FAILURES+1))
fi

fi

# ================================================================ ACTIVATION ==

step "Tools"

sudo systemctl daemon-reload

# Installed before any activation, so a later failure still leaves the
# diagnostic in place.
install_tool() {
    local src=$1 dst=$2
    if [ "$src" -ef "$dst" ]; then
        ok "$dst is the source file itself; left alone"
        return 0
    fi
    sudo install -m 755 "$src" "$dst" || die "could not install $dst from $src"
    ok "installed $dst"
}

install_tool "$SRCDIR/check.sh" /usr/local/bin/check.sh

if [ "$MACHINE_ROLE" = data ]; then
    install_tool "$SRCDIR/role" /usr/local/bin/role
fi

step "Services"

RESTARTED=""
for u in $CHANGED_UNITS; do
    systemctl is-active --quiet "$u" || continue
    case "$u" in
        nginx) sudo systemctl reload nginx ;;
        *)     sudo systemctl restart "$u" ;;
    esac
    RESTARTED="$RESTARTED $u"
done
[ -n "$RESTARTED" ] && ok "restarted changed units already running:$RESTARTED"

if [ "$MACHINE_ROLE" = emitter ]; then
    sudo systemctl enable --now ssh >/dev/null 2>&1
    sudo systemctl enable --now notify-images >/dev/null 2>&1 \
        || die "notify-images failed to start. journalctl -u notify-images -n 20"
    ok "notify-images enabled and running"
    sudo systemctl enable --now acq-hash >/dev/null 2>&1 \
        || die "acq-hash failed to start. journalctl -u acq-hash -n 20"
    ok "acq-hash enabled and running"
    sudo systemctl enable --now reaper.timer >/dev/null 2>&1 \
        || die "reaper.timer failed to start. systemctl status reaper.timer"
    ok "reaper.timer enabled"
fi

if [ "$MACHINE_ROLE" = data ]; then
    sudo systemctl enable --now ssh cron >/dev/null 2>&1

    # Never impose a role on a machine that already has one, and never
    # silently demote a machine that is currently doing the job.
    if [ -f "$ROLE_FILE" ]; then
        CURRENT_ROLE=$(cat "$ROLE_FILE")
        note "role is $CURRENT_ROLE (from $ROLE_FILE); re-applying it"
        /usr/local/bin/role "$CURRENT_ROLE" || die "role $CURRENT_ROLE failed."
    elif systemctl is-enabled --quiet pull-images 2>/dev/null; then
        CURRENT_ROLE=active
        echo active | sudo tee "$ROLE_FILE" >/dev/null
        note "no role recorded, but pull-images is enabled. Adopting 'active'
            rather than demoting a machine that is doing the job. Run
            'role spare' to demote it."
        /usr/local/bin/role active || die "role active failed."
    else
        case "$HOST" in
            concordia1) CURRENT_ROLE=active ;;
            concordia2) CURRENT_ROLE=spare ;;
        esac
        note "no role recorded. Applying the default for $HOST: $CURRENT_ROLE"
        /usr/local/bin/role "$CURRENT_ROLE" || die "role $CURRENT_ROLE failed."
    fi
fi


# ==================================================================== SUMMARY ==

step "Summary"

say "   host              $HOST"
say "   machine role      $MACHINE_ROLE"
say "   interface         $IFACE"
say "   address           $MY_IP"
[ "$MACHINE_ROLE" = data ] && say "   concordia role    ${CURRENT_ROLE:-unknown}"
say ""
say "   The transfer, notification, hashing and retention layers are installed."

if [ "$DEFERRED" -eq 1 ]; then
    say ""
    say "   VERIFICATION DEFERRED. This machine is not on the instrument LAN."
    say "   Everything is installed and configured. Nothing that needs the LAN"
    say "   was tested. This is the expected result on the cryocontrol cold"
    say "   spare and is not a failure."
fi

if [ "$FAILURES" -gt 0 ]; then
    say ""
    say "   $FAILURES item(s) above need attention. Re-run setup.sh after fixing them."
    say "   Then run: check.sh"
    exit 1
fi

say ""
say "   Now run: check.sh"
exit 0
