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

makefile root:root 0644 "$tmp"/etc/modules <<EOF
xen_netback
xen_blkback
xenfs
xen-platform-pci
xen_wdt
tun
EOF

mkdir -p "$tmp"/etc/modules-load.d
makefile root:root 0644 "$tmp"/etc/modules-load.d/xen.conf <<EOF
xen_netback
xen_blkback
xenfs
xen-platform-pci
xen_wdt
tun
EOF

mkdir -p "$tmp"/etc/network
makefile root:root 0644 "$tmp"/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback
EOF

mkdir -p "$tmp"/etc/pacman.d
makefile root:root 0644 "$tmp"/etc/pacman.d/world <<EOF
base
glibc
pacman
xen
EOF

# OpenRC support
rc_add devfs sysinit 2>/dev/null || true
rc_add dmesg sysinit 2>/dev/null || true
rc_add udev sysinit 2>/dev/null || true

rc_add hwclock boot 2>/dev/null || true
rc_add modules boot 2>/dev/null || true
rc_add sysctl boot 2>/dev/null || true
rc_add hostname boot 2>/dev/null || true
rc_add bootmisc boot 2>/dev/null || true
rc_add syslog boot 2>/dev/null || true

rc_add udev-postmount default 2>/dev/null || true
rc_add xenstored default 2>/dev/null || true
rc_add xenconsoled default 2>/dev/null || true

rc_add mount-ro shutdown 2>/dev/null || true
rc_add killprocs shutdown 2>/dev/null || true
rc_add savecache shutdown 2>/dev/null || true

# Systemd support
systemd_enable xenstored.service multi-user.target 2>/dev/null || true
systemd_enable xenconsoled.service multi-user.target 2>/dev/null || true

tar -c -C "$tmp" etc | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
ln -sf "$HOSTNAME.apkovl.tar.gz" "$HOSTNAME.kovl.tar.gz"
