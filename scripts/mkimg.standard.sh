# mkimg.standard.sh - Standard image profile for Krelpin Linux (Mobile & Multi-arch)
# Focus: aarch64 (primary mobile target), x86_64, armv7, riscv64
# Includes: Full base toolchain, coreutils, pacman, OpenRC, doas, networking

build_packages() {
	local _pkgsdir="$DESTDIR/packages"
	local _archdir="$_pkgsdir/$ARCH"
	mkdir -p "$_archdir"

	# Copy locally built packages if available
	if [ -d "$scriptdir/../packages/$ARCH" ]; then
		for pkg in "$scriptdir/../packages/$ARCH"/*.pkg.tar.*; do
			[ -f "$pkg" ] || continue
			cp -n "$pkg" "$_archdir"/ 2>/dev/null || true
		done
	fi

	# Generate Krelpin pacman repository database: krelpin.db.tar.zst
	if ls "$_archdir"/*.pkg.tar.* >/dev/null 2>&1; then
		if command -v repo-add >/dev/null 2>&1; then
			repo-add "$_archdir/krelpin.db.tar.zst" "$_archdir"/*.pkg.tar.* 2>/dev/null || true
			ln -sf krelpin.db.tar.zst "$_archdir/krelpin.db" 2>/dev/null || true
			ln -sf krelpin.files.tar.zst "$_archdir/krelpin.files" 2>/dev/null || true
			ln -sf krelpin.db.tar.zst "$_archdir/main.db.tar.zst" 2>/dev/null || true
			ln -sf krelpin.db.tar.zst "$_archdir/main.db" 2>/dev/null || true
		fi
		touch "$_pkgsdir/.boot_repository"
	fi
}

section_packages() {
	local target_pkgs="${pkgs:-$apks}"
	[ -n "$target_pkgs" ] || return 0
	local id
	id=$(echo "$target_pkgs" | tr ' ' '\n' | sort | checksum)
	build_section packages "$ARCH" "$id"
}

# Image output builders: rootfs (tarball) and img (raw disk image)
create_image_rootfs() {
	msg "Creating Krelpin rootfs archive: ${output_filename}"
	local _script="$scriptdir/genrootfs.sh"
	local output_file="${OUTDIR:-.}/$output_filename"

	if [ -f "$_script" ]; then
		fakeroot "$_script" \
			-k "$PACROOT"/etc/pacman.d/gnupg \
			-c "$PACCONF" \
			-o "$output_file" \
			-a "$ARCH" \
			$pkgs
	else
		tar --numeric-owner --exclude='dev/*' \
			--mtime="@${SOURCE_DATE_EPOCH}" \
			--owner=0 --group=0 \
			-c -C "${DESTDIR}" . | gzip -9n > "$output_file"
	fi
}

create_image_targz() {
	msg "Creating tar.gz image: ${output_filename}"
	tar -C "${DESTDIR}" \
		--mtime="@${SOURCE_DATE_EPOCH}" \
		--owner=0 --group=0 --numeric-owner \
		-chzf "${OUTDIR}/${output_filename}" .
}

create_image_img() {
	msg "Creating raw flashable disk image for mobile: ${output_filename}"
	local imgfile="${OUTDIR}/${output_filename}"
	local image_size
	image_size=$(du -L -k -s "$DESTDIR" 2>/dev/null | awk '{print int(($1 + 32768) / 1024)}')
	[ -n "$image_size" ] && [ "$image_size" -gt 256 ] || image_size=512

	dd if=/dev/zero of="$imgfile" bs=1M count="$image_size" status=none
	echo 'start=2048, type=83, bootable' | sfdisk "$imgfile" >/dev/null 2>&1 || true
	mkfs.ext4 -F -L "krelpin-root" -d "$DESTDIR" "$imgfile" 2>/dev/null || true
	gzip -f -9 "$imgfile" 2>/dev/null || true
}

profile_standard() {
	title="Krelpin Standard (Mobile & General)"
	desc="Krelpin mobile-first operating system.
		Includes standard base toolchain (gcc, binutils, glibc, make),
		core utilities (coreutils, bash, pacman), and networking.
		Primary target: aarch64 (mobile), with x86_64, armv7, riscv64 support."
	profile_abbrev="std"
	
	# Mobile first architecture list: aarch64 is primary!
	arch="aarch64 x86_64 armv7 riscv64"
	
	# Default output format: rootfs tarball (standard for mobile flashing/chroots)
	output_format="${IMAGE_FORMAT:-rootfs}"
	case "$output_format" in
		img) image_ext="img.gz" ;;
		*)   output_format="rootfs"; image_ext="tar.gz" ;;
	esac

	# Android-based mobile devices run Android/vendor kernel (boot.img), no desktop Linux kernel
	kernel_flavors=""

	# Package list: Main repo package selection
	# 1. Base Toolchain
	local _toolchain="filesystem glibc gcc binutils linux-api-headers make patch pkgconf fakeroot"

	# 2. Core Utilities & System Base
	local _coreutils="coreutils bash pacman pacman-mirrorlist krelpin-keyring
		tar gzip bzip2 xz zstd findutils grep sed gawk diffutils
		file which curl util-linux iproute2 kmod shadow doas e2fsprogs"

	# 3. Mobile Hardware, OpenRC Init & Networking
	local _mobile="openrc dhcpcd iw wpa_supplicant tzdata procps-ng inetutils kbd"

	pkgs="$_toolchain $_coreutils $_mobile"
	apks="$pkgs"

	hostname="krelpin"
	image_name="krelpin-standard"
}
