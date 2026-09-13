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

makepkg_opts="-f --noconfirm --skippgpcheck --nocheck -d"
if [ "$1" = "-k" ] || [ "$1" = "--keep" ]; then
	makepkg_opts="$makepkg_opts --holdver"
	shift
fi

CTARGET="$1"
CHOST="${CBUILD}"
CARCH="${CBUILD_ARCH}"
SUDO_PACMAN="${SUDO_PACMAN:-pacman}"
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
	SUDO_PACMAN="sudo $SUDO_PACMAN"
fi

[ $# -gt 0 ] && shift

# optional cross build packages
#: ${KERNEL_PKG="linux-firmware linux"}
#: ${OPENSSH="openssh"}
#: ${MKINITFS="libcap-ng ncurses readline sqlite util-linux libaio lvm2 popt xz json-c argon2 cryptsetup kmod mkinitcpio"}
# Some languages that need to be cross compiled
: ${GO="community/go"}
: ${LLVM_DEPS="libffi brotli libev c-ares cunit nghttp2 nghttp3 libidn2 libunistring libpsl curl libssh2 libxml2"}
: ${RUST="llvm rust"}
#: ${COMPILER_PKG="$GO $LLVM_DEPS $RUST"}

if [ -z "$CTARGET" ]; then
	CTARGET="aarch64"
	echo "No target architecture specified; defaulting to aarch64 (mobile primary target)."
fi


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
	if [ ! -f "$pkgbuild" ]; then
		die "PKGBUILD not found: $pkgbuild"
	fi
	(
		cd "$pkgdir"
		msg "Building $(basename "$pkgdir") with makepkg..."
		makepkg "$@"
		if [ -d "$CBUILDROOT" ]; then
			for pkgfile in *.pkg.tar.*; do
				[ -f "$pkgfile" ] || continue
				case "$pkgfile" in *.sig) continue ;; esac
				msg "Installing $pkgfile into $CBUILDROOT..."
				fakeroot pacman --config "$CBUILDROOT/etc/pacman.conf" -U --noconfirm --root "$CBUILDROOT" --overwrite '*' --nodeps "$pkgfile" 2>/dev/null || true
				# Also register into Krelpin binary repository
				mkdir -p "$KPORTS/packages/$CTARGET_ARCH"
				cp -f "$pkgfile" "$KPORTS/packages/$CTARGET_ARCH/"
				repo-add "$KPORTS/packages/$CTARGET_ARCH/krelpin.db.tar.zst" "$KPORTS/packages/$CTARGET_ARCH/$pkgfile" 2>/dev/null || true
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

if [ ! -d "$CBUILDROOT" ]; then
	msg "Creating sysroot in $CBUILDROOT"
	mkdir -p "$CBUILDROOT"/etc/pacman.d/gnupg "$CBUILDROOT"/var/lib/pacman "$CBUILDROOT"/var/cache/pacman/pkg

	# Usr-merged directory structure
	mkdir -p "$CBUILDROOT"/usr/lib "$CBUILDROOT"/usr/bin "$CBUILDROOT"/usr/sbin
	ln -sf usr/bin "$CBUILDROOT"/bin
	ln -sf usr/bin "$CBUILDROOT"/sbin
	ln -sf usr/lib "$CBUILDROOT"/lib
	if [ "$CTARGET_ARCH" = "x86_64" ]; then
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

# 7. Cross build tools / base-devel
BOOTSTRAP=nobase PKGBUILD=$(pkgbuildname base-devel) build_pkg $makepkg_opts

msg "Cross building base system"

# Implicit dependencies for early targets
export EXTRADEPENDS_TARGET="libgcc libstdc++ glibc"

# On a few architectures like riscv64 we need to account for
# gcc requiring -latomic to be set explicitly if a C[++]11 program uses atomics
if [ "$CTARGET_ARCH" = "riscv64" ]; then
	NEEDS_LIBATOMIC="yes"
fi

if [ $# -eq 0 ]; then
	set -- linux-api-headers glibc zlib pkgconf gmp mpfr \
	   mpc isl zstd binutils gcc make file patch openssl \
	   ca-certificates libarchive libcap pacman pacman-mirrorlist \
	   base base-devel attr acl fakeroot tar bash coreutils \
	   util-linux sed gawk grep diffutils findutils which curl kmod xz bzip2 gzip \
	   $OPENSSH \
	   $MKINITFS \
	   $COMPILER_PKG \
	   $KERNEL_PKG
fi

for PKG; do
	CHOST=$CTARGET CARCH=$CTARGET_ARCH BOOTSTRAP=bootimage PKGBUILD=$(pkgbuildname "$PKG") build_pkg $makepkg_opts

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
