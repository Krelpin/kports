#!/bin/sh -e

cleanup() {
	rm -rf "$tmp"
}

tmp="$(mktemp -d)"
trap cleanup EXIT
chmod 0755 "$tmp"

scriptdir="$(cd "$(dirname "$0")" && pwd -P)"
[ -f "$scriptdir/functions.sh" ] && . "$scriptdir/functions.sh"

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

# Pacman internal state directories
mkdir -p "$tmp"/etc/pacman.d "$tmp"/var/lib/pacman "$tmp"/var/cache/pacman/pkg

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
DBPath = $tmp/var/lib/pacman
CacheDir = $tmp/var/cache/pacman/pkg

EOF
	cat "$repositories_file" >> "$conf"
else
	cat > "$conf" <<EOF
[options]
Architecture = $arch
CheckSpace
SigLevel = Never
DBPath = $tmp/var/lib/pacman
CacheDir = $tmp/var/cache/pacman/pkg

[krelpin]
SigLevel = Never
Server = file://$scriptdir/../packages/$arch
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
	set -- filesystem glibc gcc binutils linux-api-headers make patch pkgconf \
		coreutils bash pacman pacman-mirrorlist krelpin-keyring \
		tar gzip bzip2 xz zstd findutils grep sed gawk diffutils \
		file which curl util-linux iproute2 kmod shadow doas e2fsprogs \
		openrc halium-overlay dhcpcd libnl iw libcap procps-ng inetutils kbd \
		ncurses readline openssl expat dbus pcsclite wpa_supplicant
fi

PACMAN_BIN="${PACMAN:-pacman}"
FAKEROOT="fakeroot"
if [ "$(id -u)" -eq 0 ]; then
	FAKEROOT=""
fi

if command -v "$PACMAN_BIN" >/dev/null 2>&1; then
	echo "Synchronizing package repositories for $arch..."
	$FAKEROOT "$PACMAN_BIN" --root "$tmp" --config "$conf" --arch "$arch" -Sy

	# Filter packages available in the active repository
	available_pkgs=""
	for p in "$@"; do
		target="$p"
		if $FAKEROOT "$PACMAN_BIN" --root "$tmp" --config "$conf" --arch "$arch" -Si "$target" >/dev/null 2>&1; then
			available_pkgs="$available_pkgs $target"
		else
			echo "Note: Package '$p' not found in Krelpin repository packages/$arch (build with: ./scripts/buildpkg.sh $p)"
		fi
	done

	if [ -n "$available_pkgs" ]; then
		echo "Installing base packages into Krelpin rootfs..."
		$FAKEROOT "$PACMAN_BIN" --root "$tmp" --config "$conf" --arch "$arch" --noconfirm -S --needed --overwrite '*' -dd $available_pkgs
	fi

	# Ensure doas symlink exists if opendoas was installed
	if [ -f "$tmp/usr/bin/opendoas" ] && [ ! -f "$tmp/usr/bin/doas" ]; then
		ln -sf opendoas "$tmp/usr/bin/doas"
	fi

	# Krelpin identification
	mkdir -p "$tmp/etc"
	echo "Krelpin Linux ($arch)" > "$tmp/etc/krelpin-release"
	cat > "$tmp/etc/os-release" <<-EOF
	NAME="Krelpin Linux"
	PRETTY_NAME="Krelpin Linux ($arch)"
	ID=krelpin
	ID_LIKE=arch
	ANSI_COLOR="0;34"
	HOME_URL="https://krelpin.org"
	EOF

	# Ensure merged-usr symlinks if needed
	[ -e "$tmp/bin" ] || ln -sf usr/bin "$tmp/bin"
	[ -e "$tmp/sbin" ] || ln -sf usr/bin "$tmp/sbin"
	[ -e "$tmp/lib" ] || ln -sf usr/lib "$tmp/lib"
	[ "$arch" = "x86_64" ] && [ ! -e "$tmp/lib64" ] && ln -sf usr/lib "$tmp/lib64"
elif command -v pacstrap >/dev/null 2>&1; then
	echo "Installing packages with pacstrap..."
	$FAKEROOT pacstrap -C "$conf" -M -K -c -N "$tmp" "$@" 2>/dev/null || true
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

echo "Archiving Krelpin rootfs into $outfile..."
$FAKEROOT tar --numeric-owner --exclude='dev/*' -c -C "$tmp" . | gzip -9n > "$outfile"
echo "Rootfs generated: $outfile ($(du -h "$outfile" | cut -f1))"
