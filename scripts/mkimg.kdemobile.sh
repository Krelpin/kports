# mkimg.kdemobile.sh - KDE Plasma Mobile profile for Krelpin Linux
#
# Follows the Ubuntu Touch architecture: the Android side runs in an LXC
# container and the Linux side drives the display and GPU through libhybris,
# rather than through a Mesa driver. See docs/hybris.md.
#
# The package sets below are the target. Ones that are not ported yet are
# listed so the gap stays visible; building this profile fails until they are.

profile_kdemobile() {
	title="Krelpin KDE Plasma Mobile"
	desc="Krelpin with the KDE Plasma Mobile shell on top of the Halium
		Android container, in the way Ubuntu Touch uses libhybris."
	profile_abbrev="kde"

	# Plasma Mobile targets phones, so only the mobile architecture for now
	arch="aarch64"

	output_format="${IMAGE_FORMAT:-rootfs}"
	case "$output_format" in
		img) image_ext="img.gz" ;;
		*)   output_format="rootfs"; image_ext="tar.gz" ;;
	esac

	kernel_flavors=""

	# Everything the minimal profile installs
	local _base="filesystem glibc gcc-libs zlib libxcrypt
		coreutils bash pacman pacman-mirrorlist krelpin-keyring libarchive
		tar gzip bzip2 xz zstd findutils grep sed gawk diffutils
		file which curl util-linux iproute2 kmod shadow doas e2fsprogs
		ncurses readline openssl expat
		openrc halium-overlay procps-ng inetutils kbd tzdata
		dhcpcd libnl iw wpa_supplicant"

	# Android container and the bionic/glibc bridge the HALs are loaded through
	local _hybris="lxc android-headers libhybris"

	# Display stack. No Mesa: the GPU is driven by the Android gralloc and
	# hwcomposer HALs via libhybris.
	local _graphics="wayland wayland-protocols libdrm libinput libevdev
		libxkbcommon eudev seatd"

	# Text and image rendering
	local _render="freetype fontconfig harfbuzz fribidi libpng libjpeg-turbo
		glib2 libffi pcre2 libxml2"

	# Qt 6
	local _qt="qt6-base qt6-declarative qt6-wayland qt6-svg qt6-5compat
		qt6-multimedia qt6-sensors qt6-positioning qt6-shadertools"

	# KDE Frameworks 6 and the Plasma Mobile shell
	local _plasma="extra-cmake-modules kf6-kirigami kf6-kcoreaddons kf6-kconfig
		kf6-ki18n kf6-kwindowsystem kf6-kirigami-addons
		plasma-workspace kwin plasma-mobile plasma-nano maliit-keyboard"

	pkgs="$_base $_hybris $_graphics $_render $_qt $_plasma"
	apks="$pkgs"

	hostname="krelpin"
	image_name="krelpin-kdemobile"
}
