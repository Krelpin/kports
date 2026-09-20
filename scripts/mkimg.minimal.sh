# mkimg.minimal.sh - Minimal core profile for Krelpin Linux
# Just enough to boot, get a console and manage packages. No toolchain.

profile_minimal() {
	title="Krelpin Minimal"
	desc="Smallest bootable Krelpin system: base utilities, OpenRC and pacman.
		Intended as the base layer other profiles build on."
	profile_abbrev="min"

	arch="aarch64 x86_64 armv7 riscv64"

	output_format="${IMAGE_FORMAT:-rootfs}"
	case "$output_format" in
		img) image_ext="img.gz" ;;
		*)   output_format="rootfs"; image_ext="tar.gz" ;;
	esac

	# Android based devices boot a vendor kernel from boot.img
	kernel_flavors=""

	# 1. Filesystem layout and C library
	local _base="filesystem glibc gcc-libs zlib libxcrypt"

	# 2. Core utilities
	local _coreutils="coreutils bash pacman pacman-mirrorlist krelpin-keyring libarchive
		tar gzip bzip2 xz zstd findutils grep sed gawk diffutils
		file which curl util-linux iproute2 kmod shadow doas e2fsprogs
		ncurses readline openssl expat"

	# 3. Init, console and networking
	local _system="openrc halium-overlay procps-ng inetutils kbd tzdata
		dhcpcd libnl iw wpa_supplicant"

	pkgs="$_base $_coreutils $_system"
	apks="$pkgs"

	hostname="krelpin"
	image_name="krelpin-minimal"
}
