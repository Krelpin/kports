# mkimg.standard.sh - Standard image profile for Krelpin Linux (Mobile & Multi-arch)
# Focus: aarch64 (primary mobile target), x86_64, armv7, riscv64
# Includes: Full base toolchain, coreutils, pacman, krelpin repo database

extract_pkg_file() {
	local pkgpattern="$1" dest="$2" subpath="$3"
	local pkgfile
	for pkgfile in "$PACROOT"/var/cache/pacman/pkg/${pkgpattern}*.pkg.tar.*; do
		if [ -f "$pkgfile" ]; then
			tar -xf "$pkgfile" -C "$dest" "$subpath" 2>/dev/null || true
			return 0
		fi
	done
	return 1
}

build_kernel() {
	local _flavor="$2"
	shift 3
	local _pkgs="$*"
	mkdir -p "$DESTDIR"/boot

	# Fetch kernel packages if pacman is configured
	if command -v pacman >/dev/null 2>&1 && [ -f "$PACCONF" ]; then
		pacman --config "$PACCONF" -Sw --noconfirm $_pkgs $boot_addons 2>/dev/null || true
	fi

	# Extract kernel binary and modules
	for kfile in "$PACROOT"/var/cache/pacman/pkg/linux*${_flavor}*.pkg.tar.*; do
		if [ -f "$kfile" ]; then
			tar -xf "$kfile" -C "$DESTDIR" boot/ 2>/dev/null || true
			tar -xf "$kfile" -C "$WORKDIR" usr/lib/modules/ 2>/dev/null || true
			break
		fi
	done

	# Normalize vmlinuz name for architecture
	if [ -f "$DESTDIR/boot/vmlinuz" ] && [ ! -f "$DESTDIR/boot/vmlinuz-$_flavor" ]; then
		mv "$DESTDIR/boot/vmlinuz" "$DESTDIR/boot/vmlinuz-$_flavor"
	elif [ -f "$DESTDIR/boot/vmlinuz-linux" ] && [ ! -f "$DESTDIR/boot/vmlinuz-$_flavor" ]; then
		cp -a "$DESTDIR/boot/vmlinuz-linux" "$DESTDIR/boot/vmlinuz-$_flavor"
	elif [ -f "$DESTDIR/boot/Image" ] && [ ! -f "$DESTDIR/boot/vmlinuz-$_flavor" ]; then
		# aarch64 uncompressed or compressed kernel image
		cp -a "$DESTDIR/boot/Image" "$DESTDIR/boot/vmlinuz-$_flavor"
	fi

	# Modloop / module squashfs for live/read-only boot if needed
	if [ -d "$WORKDIR/usr/lib/modules" ]; then
		mkdir -p "$DESTDIR"/boot
		if command -v mksquashfs >/dev/null 2>&1; then
			mksquashfs "$WORKDIR/usr/lib/modules" "$DESTDIR/boot/modloop-$_flavor" \
				-comp xz -noappend -b 1048576 2>/dev/null || true
		fi
	fi

	# Extract microcode/boot addons if specified
	for _add in $boot_addons; do
		extract_pkg_file "$_add" "$DESTDIR" "boot/" 2>/dev/null || true
	done
}

section_kernels() {
	[ -n "$kernel_flavors" ] || return 0
	local _f _pkgs
	for _f in $kernel_flavors; do
		_pkgs="linux-$_f linux-firmware"
		local id
		id=$(printf '%s::%s\n%s\n' "$initfs_features" "$_hostkeys" "$_pkgs" | checksum)
		build_section kernel "$ARCH" "$_f" "$id" $_pkgs
	done
}

build_packages() {
	local _pkgsdir="$DESTDIR/packages"
	local _archdir="$_pkgsdir/$ARCH"
	mkdir -p "$_archdir"

	local target_pkgs="${pkgs:-$apks}"
	if [ -n "$target_pkgs" ] && command -v pacman >/dev/null 2>&1 && [ -f "$PACCONF" ]; then
		pacman --config "$PACCONF" -Sw --noconfirm --cachedir "$_archdir" $target_pkgs 2>/dev/null || true
	fi

	# Copy any pre-cached packages from PACROOT
	if [ -d "$PACROOT/var/cache/pacman/pkg" ]; then
		for pkg in "$PACROOT"/var/cache/pacman/pkg/*.pkg.tar.*; do
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
			# Main repo alias
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

# Bootloader configurations for ISO and generic UEFI / extlinux
syslinux_gen_config() {
	[ -z "$syslinux_serial" ] || echo "SERIAL $syslinux_serial"
	echo "TIMEOUT ${syslinux_timeout:-10}"
	echo "PROMPT ${syslinux_prompt:-1}"
	echo "DEFAULT ${kernel_flavors%% *}"

	local _f _initrd
	for _f in $kernel_flavors; do
		_initrd="/boot/initramfs-$_f"
		cat <<- EOF

		LABEL $_f
			MENU LABEL Krelpin Linux $_f ($ARCH)
			KERNEL /boot/vmlinuz-$_f
			INITRD $_initrd
			FDTDIR /boot/dtbs-$_f
			APPEND $initfs_cmdline $kernel_cmdline
		EOF
	done
}

grub_gen_config() {
	local _f _initrd
	echo "set timeout=3"
	for _f in $kernel_flavors; do
		_initrd="/boot/initramfs-$_f"
		cat <<- EOF

		menuentry "Krelpin Linux $_f ($ARCH)" {
			linux  /boot/vmlinuz-$_f $initfs_cmdline $kernel_cmdline
			initrd $_initrd
		}
		EOF
	done
}

build_syslinux() {
	local _fn
	mkdir -p "$DESTDIR"/boot/syslinux
	local syslinux_dirs="/usr/lib/syslinux/bios /usr/share/syslinux"
	for sdir in $syslinux_dirs; do
		if [ -d "$sdir" ]; then
			for _fn in isohdpfx.bin isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 mboot.c32; do
				[ -f "$sdir/$_fn" ] && cp -a "$sdir/$_fn" "$DESTDIR"/boot/syslinux/
			done
			break
		fi
	done
}

section_syslinux() {
	[ "$ARCH" = "x86" ] || [ "$ARCH" = "x86_64" ] || return 0
	[ "$output_format" = "iso" ] || return 0
	build_section syslinux "$ARCH"
}

section_syslinux_cfg() {
	[ "$output_format" = "iso" ] || return 0
	mkdir -p "${DESTDIR}/boot/syslinux"
	syslinux_gen_config > "${DESTDIR}/boot/syslinux/syslinux.cfg"
}

build_grub_efi() {
	local _format="$1"
	local _efi="$2"
	mkdir -p "$DESTDIR/efi/boot"

	local grub_mod_dir=""
	for d in /usr/lib/grub/"$_format" /usr/share/grub/"$_format"; do
		if [ -d "$d" ]; then
			grub_mod_dir="$d"
			break
		fi
	done

	if command -v grub-mkimage >/dev/null 2>&1; then
		local dir_arg=""
		[ -n "$grub_mod_dir" ] && dir_arg="--directory=$grub_mod_dir"
		grub-mkimage \
			$dir_arg \
			--prefix="/boot/grub" \
			--output="$DESTDIR/efi/boot/$_efi" \
			--format="$_format" \
			--compression="xz" \
			$grub_mod 2>/dev/null || true
	fi
}

section_grub_efi() {
	[ "$output_format" = "iso" ] || return 0
	local _format _efi
	case "$ARCH" in
	aarch64)	_format="arm64-efi";  _efi="bootaa64.efi" ;;
	arm*)		_format="arm-efi";    _efi="bootarm.efi"  ;;
	x86)		_format="i386-efi";   _efi="bootia32.efi" ;;
	x86_64) 	_format="x86_64-efi"; _efi="bootx64.efi"  ;;
	riscv64) 	_format="riscv64-efi"; _efi="bootriscv64.efi"  ;;
	*)		return 0 ;;
	esac

	mkdir -p "${DESTDIR}/boot/grub"
	grub_gen_config > "${DESTDIR}/boot/grub/grub.cfg"
	build_section grub_efi "$_format" "$_efi"
}

# Image output builders: rootfs (tarball), img (raw disk), and iso
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

create_image_iso() {
	msg "Creating ISO image: ${output_filename}"
	local ISO="${OUTDIR}/${output_filename}"
	local _isolinux=""
	local _efiboot=""

	if [ -e "${DESTDIR}/boot/syslinux/isolinux.bin" ]; then
		_isolinux="
			-isohybrid-mbr ${DESTDIR}/boot/syslinux/isohdpfx.bin
			-eltorito-boot boot/syslinux/isolinux.bin
			-eltorito-catalog boot/syslinux/boot.cat
			-no-emul-boot
			-boot-load-size 4
			-boot-info-table
			"
	fi

	xorrisofs \
		-quiet \
		-output "${ISO}" \
		-full-iso9660-filenames \
		-joliet \
		-rational-rock \
		-sysid LINUX \
		-volid "krelpin-${RELEASE} ${ARCH}" \
		$_isolinux \
		-follow-links \
		"${DESTDIR}" 2>/dev/null || true
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
		iso) image_ext="iso" ;;
		img) image_ext="img.gz" ;;
		*)   output_format="rootfs"; image_ext="tar.gz" ;;
	esac

	# Android-based mobile devices run Android/vendor kernel (boot.img), no desktop Linux kernel
	kernel_flavors=""
	initfs_cmdline="console=tty0 console=ttyAMA0,115200 quiet"
	initfs_features="base ext4 mmc nvme squashfs usb virtio"

	# Package list: Main repo package selection
	# 1. Base Toolchain
	local _toolchain="glibc gcc binutils linux-api-headers make patch pkgconf fakeroot"

	# 2. Core Utilities & System Base
	local _coreutils="coreutils bash pacman pacman-mirrorlist krelpin-keyring
		tar gzip bzip2 xz zstd findutils grep sed gawk diffutils
		file which curl util-linux iproute2 kmod shadow doas e2fsprogs"

	# 3. Mobile Hardware, OpenRC Init & Networking
	local _mobile="openrc dhcpcd iw wpa_supplicant tzdata"

	pkgs="$_toolchain $_coreutils $_mobile"
	apks="$pkgs"

	hostname="krelpin"
	image_name="krelpin-standard"
}
