#!/bin/sh -e

cleanup() {
	rm -rf "$tmp"
}

tmp="$(mktemp -d)"
trap cleanup EXIT
chmod 0755 "$tmp"

# Mobile first default architecture: aarch64
arch="${ARCH:-aarch64}"
repositories_file=""
pacman_conf=""
keys_dir=/etc/pacman.d/gnupg

usage() {
	echo "usage: $0 [-a arch] [-r repos_file] [-c pacman_conf] [-k keys_dir] [-o outfile] [package...]"
	echo "Default architecture: aarch64 (mobile primary). Supports x86_64, armv7, riscv64."
	exit 0
}

while getopts "a:r:c:k:o:h" opt; do
	case $opt in
	a) arch="$OPTARG";;
	r) repositories_file="$OPTARG";;
	c) pacman_conf="$OPTARG";;
	k) keys_dir="$OPTARG";;
	o) outfile="$OPTARG";;
	h) usage;;
	*) usage;;
	esac
done
shift $(( OPTIND - 1 ))

if [ -z "$outfile" ]; then
	outfile="krelpin-rootfs-$arch.tar.gz"
fi

# Modern glibc pacman systems use merged usr
mkdir -p "$tmp"/usr/lib "$tmp"/usr/bin "$tmp"/usr/sbin "$tmp"/etc/pacman.d "$tmp"/var/lib/pacman "$tmp"/var/cache/pacman/pkg
ln -sf usr/bin "$tmp"/bin
ln -sf usr/bin "$tmp"/sbin
ln -sf usr/lib "$tmp"/lib
if [ "$arch" = "x86_64" ]; then
	ln -sf usr/lib "$tmp"/lib64
fi

# Distro identification
echo "Krelpin Linux ($arch)" > "$tmp"/etc/krelpin-release
cat > "$tmp"/etc/os-release <<-EOF
NAME="Krelpin Linux"
PRETTY_NAME="Krelpin Linux ($arch)"
ID=krelpin
ID_LIKE=arch
ANSI_COLOR="0;34"
HOME_URL="https://krelpin.org"
EOF

# Prepare pacman configuration
conf="$tmp/etc/pacman.conf"
if [ -n "$pacman_conf" ] && [ -f "$pacman_conf" ]; then
	cp "$pacman_conf" "$conf"
elif [ -n "$repositories_file" ] && [ -f "$repositories_file" ]; then
	cat > "$conf" <<EOF
[options]
Architecture = $arch
CheckSpace
SigLevel = Never

[krelpin]
SigLevel = Never

[main]
SigLevel = Never

EOF
	cat "$repositories_file" >> "$conf"
elif [ -f /etc/pacman.conf ]; then
	cp /etc/pacman.conf "$conf"
else
	cat > "$conf" <<EOF
[options]
Architecture = $arch
CheckSpace
SigLevel = Never

[krelpin]
SigLevel = Never
Server = file:///var/cache/pacman/pkg

[main]
SigLevel = Never
Server = file:///var/cache/pacman/pkg
EOF
fi

# Ensure Architecture is set correctly in temp conf
sed -i "s/^Architecture = .*/Architecture = $arch/" "$conf" 2>/dev/null || true

# Initialize keyring if keys_dir exists
if [ -d "$keys_dir" ]; then
	mkdir -p "$tmp/etc/pacman.d/gnupg"
	cp -a "$keys_dir"/* "$tmp/etc/pacman.d/gnupg/" 2>/dev/null || true
fi

# Default packages: Toolchains + Coreutils & Base System + OpenRC & Networking
if [ $# -eq 0 ]; then
	set -- glibc gcc binutils linux-api-headers make patch pkgconf \
		coreutils bash pacman pacman-mirrorlist krelpin-keyring \
		tar gzip bzip2 xz zstd findutils grep sed gawk diffutils \
		file which curl util-linux iproute2 kmod shadow doas e2fsprogs \
		openrc dhcpcd iw wpa_supplicant
fi

PACMAN_BIN="${PACMAN:-pacman}"
if command -v pacstrap >/dev/null 2>&1; then
	pacstrap -C "$conf" -M -d "$tmp" "$@"
elif command -v "$PACMAN_BIN" >/dev/null 2>&1; then
	"$PACMAN_BIN" --root "$tmp" --config "$conf" --arch "$arch" --noconfirm -Sy "$@"
else
	echo "Notice: Neither pacstrap nor pacman found on host. Skeleton rootfs created."
fi

rm -f "$tmp"/var/log/pacman.log
rm -rf "$tmp"/var/cache/pacman/pkg/*

# Busybox symlinks if present
for bb in "$tmp"/bin/busybox "$tmp"/usr/bin/busybox; do
	if [ -x "$bb" ]; then
		for link in $("$bb" --list-full 2>/dev/null); do
			[ -e "$tmp"/$link ] || ln -sf /usr/bin/busybox "$tmp"/$link 2>/dev/null || true
		done
		break
	fi
done

# Set root user configuration
if [ -f "$tmp"/etc/shadow ]; then
	sed -i -e 's/^root::/root:*:/' "$tmp"/etc/shadow
	chgrp 42 "$tmp"/etc/shadow 2>/dev/null || true
fi

tar --numeric-owner --exclude='dev/*' -c -C "$tmp" . | gzip -9n > "$outfile"
echo "Rootfs generated: $outfile"
