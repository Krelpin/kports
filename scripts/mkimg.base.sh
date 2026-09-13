# mkimg.base.sh - Base image build plugins for pacman/glibc system

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
	local _flavor="$2" _modloopsign= _add
	shift 3
	local _pkgs="$*"
	mkdir -p "$DESTDIR"/boot

	# If pacman is available, attempt to download kernel packages to cache
	if command -v pacman >/dev/null 2>&1 && [ -f "$PACCONF" ]; then
		pacman --config "$PACCONF" -Sw --noconfirm $_pkgs $boot_addons 2>/dev/null || true
	fi

	# Look for kernel binary and modules
	local kern_found=0
	for kfile in "$PACROOT"/var/cache/pacman/pkg/linux*${_flavor}*.pkg.tar.*; do
		if [ -f "$kfile" ]; then
			tar -xf "$kfile" -C "$DESTDIR" boot/ 2>/dev/null || true
			# Look for vmlinuz in /usr/lib/modules or /boot
			tar -xf "$kfile" -C "$WORKDIR" usr/lib/modules/ 2>/dev/null || true
			kern_found=1
			break
		fi
	done

	# Handle vmlinuz renaming/linking to standard /boot/vmlinuz-$_flavor
	if [ -f "$DESTDIR/boot/vmlinuz" ] && [ ! -f "$DESTDIR/boot/vmlinuz-$_flavor" ]; then
		mv "$DESTDIR/boot/vmlinuz" "$DESTDIR/boot/vmlinuz-$_flavor"
	elif [ -f "$DESTDIR/boot/vmlinuz-linux" ] && [ ! -f "$DESTDIR/boot/vmlinuz-$_flavor" ]; then
		cp -a "$DESTDIR/boot/vmlinuz-linux" "$DESTDIR/boot/vmlinuz-$_flavor"
	fi

	# Generate modloop squashfs if modules exist
	if [ -d "$WORKDIR/usr/lib/modules" ]; then
		mkdir -p "$DESTDIR"/boot
		if command -v mksquashfs >/dev/null 2>&1; then
			mksquashfs "$WORKDIR/usr/lib/modules" "$DESTDIR/boot/modloop-$_flavor" \
				-comp xz -noappend -b 1048576 2>/dev/null || true
		fi
	fi

	# Extract boot addons (e.g. microcode)
	for _add in $boot_addons; do
		extract_pkg_file "$_add" "$DESTDIR" "boot/" 2>/dev/null || true
	done
}

section_kernels() {
	local _f _a _pkgs
	for _f in $kernel_flavors; do
		_pkgs="linux-$_f linux-firmware $modloop_addons"
		for _a in $kernel_addons; do
			_pkgs="$_pkgs $_a-$_f"
		done
		local id
		id=$(printf '%s::%s\n%s\n' "$initfs_features" "$_hostkeys" "$_pkgs" | checksum)
		build_section kernel "$ARCH" "$_f" "$id" $_pkgs
	done
}

build_packages() {
	local _pkgsdir="$DESTDIR/packages"
	local _archdir="$_pkgsdir/$ARCH"
	mkdir -p "$_archdir"
	mkdir -p "$DESTDIR/apks"
	ln -sf "../packages/$ARCH" "$DESTDIR/apks/$ARCH" 2>/dev/null || true

	local target_pkgs="${pkgs:-$apks}"
	if [ -n "$target_pkgs" ] && command -v pacman >/dev/null 2>&1 && [ -f "$PACCONF" ]; then
		pacman --config "$PACCONF" -Sw --noconfirm --cachedir "$_archdir" $target_pkgs 2>/dev/null || true
	fi

	# If pre-cached packages exist in PACROOT, copy them over
	if [ -d "$PACROOT/var/cache/pacman/pkg" ]; then
		for pkg in "$PACROOT"/var/cache/pacman/pkg/*.pkg.tar.*; do
			[ -f "$pkg" ] || continue
			cp -n "$pkg" "$_archdir"/ 2>/dev/null || true
		done
	fi

	# Generate repo database using repo-add if packages exist
	if ls "$_archdir"/*.pkg.tar.* >/dev/null 2>&1; then
		if command -v repo-add >/dev/null 2>&1; then
			repo-add "$_archdir/kports.db.tar.zst" "$_archdir"/*.pkg.tar.* 2>/dev/null || true
			ln -sf kports.db.tar.zst "$_archdir/kports.db" 2>/dev/null || true
			ln -sf kports.files.tar.zst "$_archdir/kports.files" 2>/dev/null || true
		fi
		touch "$_pkgsdir/.boot_repository"
		touch "$DESTDIR/apks/.boot_repository"
	fi
}

build_apks() {
	build_packages "$@"
}

section_packages() {
	local target_pkgs="${pkgs:-$apks}"
	[ -n "$target_pkgs" ] || return 0
	local id
	id=$(echo "$target_pkgs" | tr ' ' '\n' | sort | checksum)
	build_section packages "$ARCH" "$id"
}

section_apks() {
	section_packages "$@"
}

build_overlay() {
	local _host="$1" _script=
	local _target="${ovl:-$apkovl}"
	msg "Generating overlay for $_host"
	for _script in "$PWD/$_target" "$HOME/.mkimage/$_target" \
		"$(readlink -f "$scriptdir/$_target" 2>/dev/null || true)" \
		"$scriptdir/$_target"; do

		if [ -f "$_script" ]; then
			break
		fi
	done
	[ -f "$_script" ] || die "could not find overlay script $_target"
	(cd "$DESTDIR"; fakeroot "$_script" "$_host")
}

build_apkovl() {
	build_overlay "$@"
}

section_overlay() {
	local _target="${ovl:-$apkovl}"
	[ -n "$_target" ] && [ -n "$hostname" ] || return 0
	build_section overlay "$hostname" "$(checksum < "$_target")"
}

section_apkovl() {
	section_overlay "$@"
}

build_syslinux() {
	local _fn
	mkdir -p "$DESTDIR"/boot/syslinux
	local syslinux_dirs="/usr/lib/syslinux/bios /usr/share/syslinux"
	for sdir in $syslinux_dirs; do
		if [ -d "$sdir" ]; then
			for _fn in isohdpfx.bin isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 mboot.c32 whichsys.c32; do
				[ -f "$sdir/$_fn" ] && cp -a "$sdir/$_fn" "$DESTDIR"/boot/syslinux/
			done
			break
		fi
	done
	# Extract from syslinux package in pacman cache if not found on host
	for pkg in "$PACROOT"/var/cache/pacman/pkg/syslinux*.pkg.tar.*; do
		[ -f "$pkg" ] || continue
		tar -xf "$pkg" -C "$DESTDIR" usr/lib/syslinux/bios/ usr/share/syslinux/ 2>/dev/null || true
		for sdir in "$DESTDIR"/usr/lib/syslinux/bios "$DESTDIR"/usr/share/syslinux; do
			if [ -d "$sdir" ]; then
				for _fn in isohdpfx.bin isolinux.bin ldlinux.c32 libutil.c32 libcom32.c32 mboot.c32; do
					[ -f "$sdir/$_fn" ] && mv "$sdir/$_fn" "$DESTDIR"/boot/syslinux/
				done
			fi
		done
		rm -rf "$DESTDIR"/usr
		break
	done
}

section_syslinux() {
	[ "$ARCH" = "x86" ] || [ "$ARCH" = "x86_64" ] || return 0
	[ "$output_format" = "iso" ] || return 0
	build_section syslinux "$ARCH"
}

syslinux_gen_config() {
	[ -z "$syslinux_serial" ] || echo "SERIAL $syslinux_serial"
	echo "TIMEOUT ${syslinux_timeout:-10}"
	echo "PROMPT ${syslinux_prompt:-1}"
	echo "DEFAULT ${kernel_flavors%% *}"

	local _f _p _initrd
	for _f in $kernel_flavors; do
		if [ -z "${xen_params+set}" ]; then
			_initrd="/boot/initramfs-$_f"
			for _p in $initrd_ucode; do
				_initrd="$_p,$_initrd"
			done

			cat <<- EOF

			LABEL $_f
				MENU LABEL Linux $_f
				KERNEL /boot/vmlinuz-$_f
				INITRD $_initrd
				FDTDIR /boot/dtbs-$_f
				APPEND $initfs_cmdline $kernel_cmdline
			EOF
		else
			cat <<- EOF

			LABEL $_f
				MENU LABEL Xen/Linux $_f
				KERNEL /boot/syslinux/mboot.c32
				APPEND /boot/xen.gz ${xen_params} --- /boot/vmlinuz-$_f $initfs_cmdline $kernel_cmdline --- /boot/initramfs-$_f
			EOF
		fi
	done
}

grub_gen_config() {
	local _f _p _initrd
	echo "set timeout=1"
	for _f in $kernel_flavors; do
		if [ -z "${xen_params+set}" ]; then
			_initrd="/boot/initramfs-$_f"
			for _p in $initrd_ucode; do
				_initrd="$_p $_initrd"
			done

			cat <<- EOF

			menuentry "Linux $_f" {
				linux	/boot/vmlinuz-$_f $initfs_cmdline $kernel_cmdline
				initrd	$_initrd
			}
			EOF
		else
			cat <<- EOF

			menuentry "Xen/Linux $_f" {
				multiboot2	/boot/xen.gz ${xen_params}
				module2		/boot/vmlinuz-$_f $initfs_cmdline $kernel_cmdline
				module2		/boot/initramfs-$_f
			}
			EOF
		fi
	done
}

build_syslinux_cfg() {
	local syslinux_cfg="$1"
	mkdir -p "${DESTDIR}/$(dirname "$syslinux_cfg")"
	syslinux_gen_config > "${DESTDIR}/$syslinux_cfg"
}

section_syslinux_cfg() {
	syslinux_cfg=""
	if [ "$ARCH" = "x86" ] || [ "$ARCH" = "x86_64" ]; then
		[ ! "$output_format" = "iso" ] || syslinux_cfg="boot/syslinux/syslinux.cfg"
	fi
	[ ! -n "$uboot_install" ] || syslinux_cfg="extlinux/extlinux.conf"
	[ -n "$syslinux_cfg" ] || return 0
	build_section syslinux_cfg "$syslinux_cfg" "$(syslinux_gen_config | checksum)"
}

build_grub_cfg() {
	local grub_cfg="$1"
	mkdir -p "${DESTDIR}/$(dirname "$grub_cfg")"
	grub_gen_config > "${DESTDIR}/$grub_cfg"
}

gen_volid() {
	printf "%s" "${distro_name:-kports}-${profile_abbrev:-$PROFILE} ${RELEASE%_rc*} $ARCH" | cut -c1-32
}

grub_gen_earlyconf() {
	cat <<- EOF
	search --no-floppy --set=root --label "$(gen_volid)"
	set prefix=(\$root)/boot/grub
	EOF
}

build_grub_efi() {
	local _format="$1"
	local _efi="$2"

	mkdir -p "$DESTDIR/efi/boot"
	grub_gen_earlyconf > "$WORKDIR/grub_early.$3.cfg"

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
			--config="$WORKDIR/grub_early.$3.cfg" \
			$dir_arg \
			--prefix="/boot/grub" \
			--output="$DESTDIR/efi/boot/$_efi" \
			--format="$_format" \
			--compression="xz" \
			$grub_mod 2>/dev/null || true
	fi
}

section_grubieee1275() {
	[ "$ARCH" = "ppc64le" ] || return 0
	[ "$output_format" = "iso" ] || return 0
	kernel_cmdline="$kernel_cmdline console=hvc0"
	build_section grub_cfg "boot/grub/grub.cfg" "$(grub_gen_config | checksum)"
}

section_grub_efi() {
	[ -n "$grub_mod" ] || return 0
	local _format _efi
	case "$ARCH" in
	aarch64)	_format="arm64-efi";  _efi="bootaa64.efi" ;;
	arm*)		_format="arm-efi";    _efi="bootarm.efi"  ;;
	x86)		_format="i386-efi";   _efi="bootia32.efi" ;;
	x86_64) 	_format="x86_64-efi"; _efi="bootx64.efi"  ;;
	riscv64) 	_format="riscv64-efi"; _efi="bootriscv64.efi"  ;;
	loongarch64)	_format="loongarch64-efi"; _efi="bootloongarch64.efi"  ;;
	*)		return 0 ;;
	esac

	build_section grub_cfg "boot/grub/grub.cfg" "$(grub_gen_config | checksum)"
	build_section grub_efi "$_format" "$_efi" "$(grub_gen_earlyconf | checksum)"
}

create_image_iso() {
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
	if [ -e "${DESTDIR}/efi" ] && [ -e "${DESTDIR}/boot/grub" ]; then
		mkdir -p "${DESTDIR}/boot/grub"
		if command -v mformat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
			mformat -i "${DESTDIR}/boot/grub/efi.img" -C -f 1440 -N 0 :: 2>/dev/null || true
			mcopy -i "${DESTDIR}/boot/grub/efi.img" -s "${DESTDIR}/efi" :: 2>/dev/null || true
			touch -md "@${SOURCE_DATE_EPOCH}" "${DESTDIR}/boot/grub/efi.img" 2>/dev/null || true
		fi

		if [ -z "$_isolinux" ]; then
			_efiboot="
				-efi-boot-part
				--efi-boot-image
				-e boot/grub/efi.img
				-no-emul-boot
				"
		else
			_efiboot="
				-eltorito-alt-boot
				-e boot/grub/efi.img
				-no-emul-boot
				-isohybrid-gpt-basdat
				"
		fi
	fi

	if [ "$ARCH" = "ppc64le" ] && command -v grub-mkrescue >/dev/null 2>&1; then
		grub-mkrescue --output "${ISO}" "${DESTDIR}" -follow-links \
			-sysid LINUX \
			-volid "$(gen_volid)"
	else
		xorrisofs \
			-quiet \
			-output "${ISO}" \
			-full-iso9660-filenames \
			-joliet \
			-rational-rock \
			-sysid LINUX \
			-volid "$(gen_volid)" \
			$_isolinux \
			$_efiboot \
			-follow-links \
			${iso_opts} \
			"${DESTDIR}"
	fi
}

create_image_targz() {
	tar -C "${DESTDIR}" \
		--mtime="@${SOURCE_DATE_EPOCH}" \
		--owner=0 --group=0 --numeric-owner \
		-chzf "${OUTDIR}/${output_filename}" .
}

profile_base() {
	kernel_flavors="lts"
	initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage quiet"
	initfs_features="ata base bootchart cdrom dhcp ext4 mmc nvme raid scsi squashfs usb virtio"
	modloop_sign=no
	grub_mod="all_video disk part_gpt part_msdos linux normal configfile search search_label efi_gop fat iso9660 cat echo ls test true help gzio"
	case "$ARCH" in
		x86*) grub_mod="$grub_mod multiboot2 efi_uga";;
	esac
	case "$ARCH" in
		x86_64) initfs_features="$initfs_features nfit";;
		arm*|aarch64|riscv64) initfs_features="$initfs_features phy";;
	esac
	pkgs="base glibc pacman bash coreutils iproute2 dhcpcd e2fsprogs
		kmod openssh openssl sudo util-linux tzdata wget curl"
	apks="$pkgs"
	apkovl=
	ovl=
	hostname="kports"
}
