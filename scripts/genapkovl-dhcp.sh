#!/bin/sh -e

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
	echo "usage: $0 hostname"
	exit 1
fi

cleanup() {
	rm -rf "$tmp"
}

makefile() {
	OWNER="$1"
	PERMS="$2"
	FILENAME="$3"
	cat > "$FILENAME"
	chown "$OWNER" "$FILENAME"
	chmod "$PERMS" "$FILENAME"
}

rc_add() {
	mkdir -p "$tmp"/etc/runlevels/"$2"
	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

systemd_enable() {
	local unit="$1" target="${2:-multi-user.target}"
	mkdir -p "$tmp"/etc/systemd/system/"${target}.wants"
	ln -sf /usr/lib/systemd/system/"$unit" "$tmp"/etc/systemd/system/"${target}.wants"/"$unit"
}

tmp="$(mktemp -d)"
trap cleanup EXIT

mkdir -p "$tmp"/etc
makefile root:root 0644 "$tmp"/etc/hostname <<EOF
$HOSTNAME
EOF

mkdir -p "$tmp"/etc/network
makefile root:root 0644 "$tmp"/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

mkdir -p "$tmp"/etc/systemd/network
makefile root:root 0644 "$tmp"/etc/systemd/network/20-wired.network <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

mkdir -p "$tmp"/etc/pacman.d
makefile root:root 0644 "$tmp"/etc/pacman.d/world <<EOF
base
glibc
pacman
EOF

# OpenRC service support
rc_add devfs sysinit 2>/dev/null || true
rc_add dmesg sysinit 2>/dev/null || true
rc_add mdev sysinit 2>/dev/null || true
rc_add hwdrivers sysinit 2>/dev/null || true
rc_add modloop sysinit 2>/dev/null || true

rc_add hwclock boot 2>/dev/null || true
rc_add modules boot 2>/dev/null || true
rc_add sysctl boot 2>/dev/null || true
rc_add hostname boot 2>/dev/null || true
rc_add bootmisc boot 2>/dev/null || true
rc_add syslog boot 2>/dev/null || true

rc_add mount-ro shutdown 2>/dev/null || true
rc_add killprocs shutdown 2>/dev/null || true
rc_add savecache shutdown 2>/dev/null || true

# Systemd service support
systemd_enable systemd-networkd.service multi-user.target 2>/dev/null || true
systemd_enable systemd-resolved.service multi-user.target 2>/dev/null || true

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
ln -sf "$HOSTNAME.apkovl.tar.gz" "$HOSTNAME.kovl.tar.gz"
