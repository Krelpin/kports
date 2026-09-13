#!/bin/sh

set -e

program=$(basename "$0")
case "$1" in
	-h|--help)
		cat <<EOF
usage: $program [CTARGET_ARCH]

This script creates a local cross-compiler, and uses it to
cross-compile the Krelpin Linux pacman/glibc base system.

Primary architecture:
  aarch64 (mobile devices, default)
Supported architectures:
  x86_64, armv7, riscv64

Example:
  ./$program aarch64
EOF
		exit 0
		;;
esac

REBUILD="no"
makepkg_opts="--noconfirm --skippgpcheck --nocheck -d"
CTARGET=""

while [ $# -gt 0 ]; do
	case "$1" in
		-f|--force)
			REBUILD="yes"
			makepkg_opts="-f $makepkg_opts"
			shift
			;;
		-k|--keep)
			makepkg_opts="$makepkg_opts --holdver"
			shift
			;;
		-*)
			shift
			;;
		*)
			if [ -z "$CTARGET" ]; then
				CTARGET="$1"
			fi
			shift
			;;
	esac
done

if [ -z "$CTARGET" ]; then
	CTARGET="aarch64"
	echo "No target architecture specified; defaulting to aarch64 (mobile primary target)."
fi

CHOST="${CBUILD}"
CARCH="${CBUILD_ARCH}"


scriptdir="$(dirname "$0")"
if [ -e "$scriptdir/functions.sh" ]; then
	. "$scriptdir/functions.sh"
elif [ -e "${ABUILD_SHAREDIR:-/usr/share/abuild}/functions.sh" ]; then
	. "${ABUILD_SHAREDIR:-/usr/share/abuild}/functions.sh"
else
	die "functions.sh not found"
fi

# Determine target architecture and triplet
case "$CTARGET" in
	x86_64)
		CTARGET_ARCH="x86_64"
		CTARGET="x86_64-pc-linux-gnu"
		;;
	aarch64|arm64)
		CTARGET_ARCH="aarch64"
		CTARGET="aarch64-unknown-linux-gnu"
		;;
	armv7|armv7l)
		CTARGET_ARCH="armv7"
		CTARGET="armv7l-unknown-linux-gnueabihf"
		;;
	riscv64)
		CTARGET_ARCH="riscv64"
		CTARGET="riscv64-unknown-linux-gnu"
		;;
	i686|x86)
		CTARGET_ARCH="x86"
		CTARGET="i686-pc-linux-gnu"
		;;
	*-*-*)
		CTARGET_ARCH="${CTARGET%%-*}"
		;;
	*)
		CTARGET_ARCH="$CTARGET"
		CTARGET="${CTARGET}-unknown-linux-gnu"
		;;
esac

# deduce kports directory
[ -z "$KPORTS" ] && KPORTS="${APORTS:-$(cd "$scriptdir/.." && pwd -P)}"
CBUILDROOT="${CBUILDROOT:-$KPORTS/sysroot-$CTARGET_ARCH}"
export CBUILD CBUILD_ARCH CHOST CARCH CTARGET CTARGET_ARCH CBUILDROOT KPORTS

pkgbuildname() {
	local repo="${1%%/*}"
	local pkg="${1##*/}"
	if [ "$repo" = "$1" ]; then
		if [ -d "$KPORTS/main/$pkg" ]; then
			repo="main"
		elif [ -d "$KPORTS/core/$pkg" ]; then
			repo="core"
		elif [ -d "$KPORTS/extra/$pkg" ]; then
			repo="extra"
		else
			repo="main"
		fi
	fi
	echo "$KPORTS/$repo/$pkg/PKGBUILD"
}

# 1:1 alias for compatibility
apkbuildname() {
	pkgbuildname "$@"
}

build_pkg() {
	local pkgbuild
	if [ -n "$PKGBUILD" ]; then
		pkgbuild="$PKGBUILD"
	else
		pkgbuild="$1"
		shift
	fi
	local pkgdir="$(dirname "$pkgbuild")"
	local pkgname="$(basename "$pkgdir")"
	if [ ! -f "$pkgbuild" ]; then
		die "PKGBUILD not found: $pkgbuild"
	fi

	# Check if package already exists in Krelpin repository
	local existing_pkg=""
	if [ -d "$KPORTS/packages/$CTARGET_ARCH" ]; then
		existing_pkg=$(find "$KPORTS/packages/$CTARGET_ARCH" -name "${pkgname}-[0-9]*.pkg.tar.*" 2>/dev/null | head -n1 || true)
	fi

	if [ -n "$existing_pkg" ] && [ "$REBUILD" != "yes" ]; then
		msg "Package '$pkgname' already exists: $(basename "$existing_pkg") (skipping build, use -f to force)"
		if [ -d "$CBUILDROOT" ]; then
			fakeroot pacman --config "$CBUILDROOT/etc/pacman.conf" -U --noconfirm --root "$CBUILDROOT" --needed --overwrite '*' -dd "$existing_pkg" 2>/dev/null || true
		fi
		return 0
	fi

	(
		cd "$pkgdir"
		if [ -d "$CBUILDROOT" ]; then
			export PKG_CONFIG_PATH="$CBUILDROOT/usr/lib/pkgconfig:$CBUILDROOT/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
			export CFLAGS="-I$CBUILDROOT/usr/include ${CFLAGS:-}"
			export CPPFLAGS="-I$CBUILDROOT/usr/include ${CPPFLAGS:-}"
			export CXXFLAGS="-I$CBUILDROOT/usr/include ${CXXFLAGS:-}"
			export LDFLAGS="-L$CBUILDROOT/usr/lib -Wl,-rpath-link,$CBUILDROOT/usr/lib ${LDFLAGS:-}"
		fi
		msg "Building $pkgname with makepkg..."
		makepkg "$@"
		if [ -d "$CBUILDROOT" ]; then
			for pkgfile in *.pkg.tar.*; do
				[ -f "$pkgfile" ] || continue
				case "$pkgfile" in *.sig) continue ;; esac
				msg "Installing $pkgfile into $CBUILDROOT..."
				fakeroot pacman --config "$CBUILDROOT/etc/pacman.conf" -U --noconfirm --root "$CBUILDROOT" --overwrite '*' -dd "$pkgfile" 2>/dev/null || true
				sed -i 's|/usr/lib/||g' "$CBUILDROOT"/usr/lib/libc.so "$CBUILDROOT"/usr/lib/libm.so 2>/dev/null || true
				# Also register into Krelpin binary repository
				mkdir -p "$KPORTS/packages/$CTARGET_ARCH"
				cp -f "$pkgfile" "$KPORTS/packages/$CTARGET_ARCH/"
				repo-add "$KPORTS/packages/$CTARGET_ARCH/krelpin.db.tar.zst" "$KPORTS/packages/$CTARGET_ARCH/$pkgfile" 2>/dev/null || true
				ln -sf "krelpin.db.tar.zst" "$KPORTS/packages/$CTARGET_ARCH/krelpin.db"
				ln -sf "krelpin.files.tar.zst" "$KPORTS/packages/$CTARGET_ARCH/krelpin.files"
			done
		fi
	)
}

msg() {
	[ -n "$quiet" ] && return 0
	local prompt="${GREEN}>>>${NORMAL}"
	local name="${BLUE}bootstrap-${CTARGET_ARCH}${NORMAL}"
	printf "${prompt} ${name}: %s\n" "$1" >&2
}

if [ ! -f "$CBUILDROOT/etc/pacman.conf" ]; then
	msg "Initializing sysroot in $CBUILDROOT"
	mkdir -p "$CBUILDROOT"/etc/pacman.d/gnupg "$CBUILDROOT"/var/lib/pacman "$CBUILDROOT"/var/cache/pacman/pkg

	# Usr-merged directory structure
	mkdir -p "$CBUILDROOT"/usr/lib "$CBUILDROOT"/usr/bin "$CBUILDROOT"/usr/sbin "$CBUILDROOT"/usr/include
	[ ! -e "$CBUILDROOT"/bin ] && ln -sf usr/bin "$CBUILDROOT"/bin
	[ ! -e "$CBUILDROOT"/sbin ] && ln -sf usr/bin "$CBUILDROOT"/sbin
	[ ! -e "$CBUILDROOT"/lib ] && ln -sf usr/lib "$CBUILDROOT"/lib
	if [ "$CTARGET_ARCH" = "x86_64" ] && [ ! -e "$CBUILDROOT"/lib64 ]; then
		ln -sf usr/lib "$CBUILDROOT"/lib64
	fi

	# Initialize pacman database and conf in sysroot
	mkdir -p "$CBUILDROOT"/var/lib/pacman/local
	cat > "$CBUILDROOT"/etc/pacman.conf <<-EOF
	[options]
	Architecture = $CTARGET_ARCH
	SigLevel = Never
	DBPath = $CBUILDROOT/var/lib/pacman
	CacheDir = $CBUILDROOT/var/cache/pacman/pkg
	EOF
fi

msg "Building cross-compiler"

# 1. Build and install cross binutils (--with-sysroot)
BOOTSTRAP=nobase PKGBUILD=$(pkgbuildname binutils) build_pkg $makepkg_opts

# 2. Target Linux API headers
CHOST=$CTARGET CARCH=$CTARGET_ARCH BOOTSTRAP=nocc PKGBUILD=$(pkgbuildname linux-api-headers) build_pkg $makepkg_opts

# 3. Target glibc headers and startup files
CHOST=$CTARGET CARCH=$CTARGET_ARCH BOOTSTRAP=headers PKGBUILD=$(pkgbuildname glibc) build_pkg $makepkg_opts

# 4. Minimal cross GCC (Pass 1 - static libgcc without glibc)
EXTRADEPENDS_HOST="linux-api-headers" \
BOOTSTRAP=nolibc PKGBUILD=$(pkgbuildname gcc) build_pkg $makepkg_opts

# 5. Cross build bootstrap glibc for target
EXTRADEPENDS_BUILD="gcc-pass2-$CTARGET_ARCH" \
CHOST=$CTARGET CARCH=$CTARGET_ARCH BOOTSTRAP=nolibc PKGBUILD=$(pkgbuildname glibc) build_pkg $makepkg_opts

# 6. Full cross GCC (Pass 2 - full gcc with glibc & C++ support)
EXTRADEPENDS_TARGET="glibc" \
BOOTSTRAP=nobase PKGBUILD=$(pkgbuildname gcc) build_pkg $makepkg_opts

# 7. Cross build tools / base-devel (if recipe exists)
if [ -f "$(pkgbuildname base-devel 2>/dev/null)" ]; then
	BOOTSTRAP=nobase PKGBUILD=$(pkgbuildname base-devel) build_pkg $makepkg_opts
fi

msg "Cross building base system"

# Implicit dependencies for early targets
export EXTRADEPENDS_TARGET="libgcc libstdc++ glibc"

# On a few architectures like riscv64 we need to account for
# gcc requiring -latomic to be set explicitly if a C[++]11 program uses atomics
if [ "$CTARGET_ARCH" = "riscv64" ]; then
	NEEDS_LIBATOMIC="yes"
fi

if [ $# -eq 0 ]; then
	set -- linux-api-headers glibc binutils gcc make file patch pkgconf \
	   zstd libarchive curl pacman pacman-mirrorlist fakeroot tar bash coreutils \
	   util-linux sed gawk grep diffutils findutils which kmod \
	   xz bzip2 gzip doas openrc dhcpcd iproute2 iw wpa_supplicant \
	   shadow e2fsprogs krelpin-keyring
fi

for PKG; do
	_pkgb="$(pkgbuildname "$PKG" 2>/dev/null || true)"
	if [ ! -f "$_pkgb" ]; then
		continue
	fi
	CHOST=$CTARGET CARCH=$CTARGET_ARCH BOOTSTRAP=bootimage PKGBUILD="$_pkgb" build_pkg $makepkg_opts

	case "$PKG" in
	linux-api-headers|glibc)
		# Additional implicit dependencies once built
		EXTRADEPENDS_TARGET="$EXTRADEPENDS_TARGET $PKG"
		;;
	gcc)
		if [ "$NEEDS_LIBATOMIC" = "yes" ]; then
			EXTRADEPENDS_TARGET="$EXTRADEPENDS_TARGET $PKG"
		fi
		;;
	base-devel)
		# After base-devel, sufficient dependency in target
		EXTRADEPENDS_TARGET="coreutils $PKG"
		;;
	esac
done
