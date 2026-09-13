build_rpi_blobs() {
	mkdir -p "${DESTDIR}"/boot
	for i in raspberrypi-bootloader raspberrypi-firmware raspberrypi-bootloader-common; do
		extract_pkg_file "$i" "${DESTDIR}" "boot/" 2>/dev/null || true
	done
	if [ -f /boot/bootcode.bin ]; then
		cp -a /boot/bootcode.bin /boot/start*.elf /boot/fixup*.dat "${DESTDIR}"/ 2>/dev/null || true
	fi
}

rpi_gen_cmdline() {
	echo "modules=loop,squashfs,sd-mod,usb-storage quiet ${kernel_cmdline}"
}

rpi_gen_config() {
	local arm_64bit=0
	case "$ARCH" in
		aarch64) arm_64bit=1;;
	esac
	cat <<-EOF
		# do not modify this file as it will be overwritten on upgrade.
		# create and/or modify usercfg.txt instead.
		# https://www.raspberrypi.com/documentation/computers/config_txt.html

		kernel=boot/vmlinuz-rpi
		initramfs boot/initramfs-rpi
		arm_64bit=$arm_64bit
		include usercfg.txt
	EOF
}

build_rpi_config() {
	rpi_gen_cmdline > "${DESTDIR}"/cmdline.txt
	rpi_gen_config > "${DESTDIR}"/config.txt
}

section_rpi_config() {
	[ "$hostname" = "rpi" ] || return 0
	local id
	id=$( (rpi_gen_cmdline ; rpi_gen_config) | checksum )
	build_section rpi_config "$id"
	build_section rpi_blobs
}

profile_rpi() {
	profile_base
	title="Raspberry Pi"
	desc="First generation Pis including Zero/W (armhf).
		Pi 2 to Pi 3+ generations (armv7).
		Pi 3 to Pi 5 generations (aarch64)."
	image_ext="tar.gz"
	arch="aarch64 armhf armv7"
	kernel_flavors="rpi"
	kernel_cmdline="brcmfmac.roamoff=1 brcmfmac.feature_disable=0x282000 console=tty1"
	initfs_features="base squashfs mmc usb kms dhcp https"
	hostname="rpi"
	grub_mod=
}

create_image_imggz() {
	MIN_IMG_SIZE=129 # minimum FAT16 partition size in MB to cross 4k cluster size boundary
	sync "$DESTDIR"
	local imgfile="${OUTDIR}/${output_filename%.gz}"
	local image_size
	image_size=$(du -L -k -s "$DESTDIR" | awk '{print int(($1 + 8192) / 1024)}' )
	dd if=/dev/zero of="$imgfile" bs=1M count=$((1 + (image_size > MIN_IMG_SIZE ? image_size : MIN_IMG_SIZE)))
	echo 'start=2048, type=6, bootable' | sfdisk "$imgfile"
	mkfs.vfat -n PIBOOT -F 16 --offset 2048 "$imgfile"
	mcopy -s -i "$imgfile"@@2048s "$DESTDIR"/* 2>/dev/null || true
	for rel in "$DESTDIR"/.kports-release "$DESTDIR"/.alpine-release; do
		[ -f "$rel" ] && mcopy -i "$imgfile"@@2048s "$rel" :: 2>/dev/null || true
	done
	echo "Compressing $imgfile..."
	pigz -v -f -9 "$imgfile" 2>/dev/null || gzip -f -9 "$imgfile"
}

profile_rpiimg() {
	profile_rpi
	title="Raspberry Pi Disk Image"
	image_name="${distro_name:-kports}-rpi"
	image_ext="img.gz"
}
