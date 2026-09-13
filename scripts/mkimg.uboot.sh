build_uboot() {
	mkdir -p "$DESTDIR"/u-boot
	local pkg
	for pkg in "$PACROOT"/var/cache/pacman/pkg/uboot*.pkg.tar.* "$PACROOT"/var/cache/pacman/pkg/u-boot*.pkg.tar.*; do
		[ -f "$pkg" ] || continue
		tar -xf "$pkg" -C "$DESTDIR" usr/ 2>/dev/null || true
	done
	if [ -d "$DESTDIR"/usr/share/u-boot ]; then
		cp -a "$DESTDIR"/usr/share/u-boot/* "$DESTDIR"/u-boot/ 2>/dev/null || true
	fi
	if [ -f "$DESTDIR"/usr/bin/update-u-boot ] || [ -f "$DESTDIR"/usr/sbin/update-u-boot ]; then
		cp -a "$DESTDIR"/usr/*bin/update-u-boot "$DESTDIR"/u-boot/ 2>/dev/null || true
	fi
	rm -rf "$DESTDIR"/usr
}

section_uboot() {
	[ -n "$uboot_install" ] || return 0
	build_section uboot "$ARCH"
}

profile_uboot() {
	profile_base
	title="Generic U-Boot"
	desc="Has default LTS kernel.
		Includes the U-Boot bootloader.
		Tarball.
		"
	image_ext="tar.gz"
	arch="aarch64 armv7 riscv64"
	kernel_flavors="lts"
	initfs_features="base ext4 kms mmc nvme phy raid scsi squashfs usb virtio"
	uboot_install="yes"
}
