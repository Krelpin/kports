profile_standard() {
	title="Standard"
	desc="Pacman/glibc base system.
		Just enough to get you started.
		Network connection is required."
	profile_base
	profile_abbrev="std"
	image_ext="iso"
	arch="aarch64 armv7 x86 x86_64 ppc64le s390x loongarch64 riscv64"
	output_format="iso"
	kernel_addons=""
	case "$ARCH" in
	riscv64)
		kernel_addons=""
		initfs_features="$initfs_features kms"
		;;
	s390x)
		pkgs="$pkgs s390-tools"
		initfs_features="$initfs_features dasd_mod qeth zfcp"
		initfs_cmdline="modules=loop,squashfs,dasd_mod,qeth,zfcp quiet"
		;;
	ppc64le)
		initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage,ibmvscsi quiet"
		;;
	esac
	pkgs="$pkgs iw wpa_supplicant"
	apks="$pkgs"
}

profile_extended() {
	profile_standard
	profile_abbrev="ext"
	title="Extended"
	desc="Most common used packages included.
		Suitable for routers, servers and rescue.
		Runs from RAM.
		Includes AMD and Intel microcode updates."
	arch="x86 x86_64"
	kernel_addons=""
	boot_addons="amd-ucode intel-ucode"
	initrd_ucode="/boot/amd-ucode.img /boot/intel-ucode.img"
	pkgs="$pkgs
		coreutils ethtool hwdata sudo
		logrotate lsof lm_sensors nano
		pciutils strace tmux
		usbutils curl wget

		ca-certificates
		dhcpcd dnsmasq htop
		iproute2 iptables iputils nftables iw links
		ncurses net-tools openvpn ppp
		socat strongswan tcpdump
		wireguard-tools wireless_tools wpa_supplicant

		btrfs-progs dosfstools cryptsetup
		e2fsprogs efibootmgr f2fs-tools
		grub lvm2 lz4 mdadm mtools nfs-utils
		parted rsync sfdisk syslinux util-linux xfsprogs zstd
		"

	local _k _a
	for _k in $kernel_flavors; do
		pkgs="$pkgs linux-$_k"
		for _a in $kernel_addons; do
			pkgs="$pkgs $_a-$_k"
		done
	done
	pkgs="$pkgs linux-firmware"
	apks="$pkgs"
}

profile_virt() {
	profile_standard
	profile_abbrev="virt"
	title="Virtual"
	desc="Similar to standard.
		Slimmed down kernel.
		Optimized for virtual systems."
	arch="aarch64 armv7 x86 x86_64"
	kernel_addons=""
	kernel_flavors="virt"
	case "$ARCH" in
		arm*|aarch64)
			kernel_cmdline="console=tty0 console=ttyAMA0"
			;;
	esac
	syslinux_serial="0 115200"
}
