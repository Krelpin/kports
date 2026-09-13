section_minirootfs() {
	return 0
}

create_image_rootfs() {
	local _script
	_script=$(readlink -f "$scriptdir/genrootfs.sh")
	local output_file
	output_file="$(readlink -f "${OUTDIR:-.}")/$output_filename"

	local target_pkgs="${rootfs_pkgs:-$rootfs_apks}"
	(cd "$OUTDIR"; fakeroot "$_script" \
		-k "$PACROOT"/etc/pacman.d/gnupg \
		-c "$PACCONF" \
		-o "$output_file" \
		-a "$ARCH" \
		$target_pkgs)
}

profile_minirootfs() {
	title="Mini root filesystem"
	desc="Minimal root filesystem.
		For use in containers
		and minimal chroots."
	image_ext=tar.gz
	output_format=rootfs
	arch="$ARCH"  # allow any arch
	rootfs_pkgs="base glibc pacman bash coreutils"
	rootfs_apks="$rootfs_pkgs"
}
