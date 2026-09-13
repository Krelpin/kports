build_xen() {
	mkdir -p "$DESTDIR"/boot
	for pkg in "$PACROOT"/var/cache/pacman/pkg/xen*.pkg.tar.*; do
		[ -f "$pkg" ] || continue
		tar -xf "$pkg" -C "$DESTDIR" boot/ 2>/dev/null || true
		break
	done
}

section_xen() {
	[ -n "${xen_params+set}" ] || return 0
	build_section xen "$ARCH"
}

profile_xen() {
	profile_standard
	profile_abbrev="xen"
	title="Xen"
	desc="Built-in support for Xen Hypervisor.
		Includes packages targeted at Xen usage.
		Use for Xen Dom0."
	arch="x86_64"
	kernel_addons=""
	xen_params=""
	pkgs="$pkgs ethtool lvm2 mdadm multipath-tools sfdisk xen syslinux"
	apks="$pkgs"

	local _k _a
	for _k in $kernel_flavors; do
		pkgs="$pkgs linux-$_k"
		for _a in $kernel_addons; do
			pkgs="$pkgs $_a-$_k"
		done
	done
	apks="$pkgs"
}
