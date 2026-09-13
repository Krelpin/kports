#!/bin/bash
# buildpkg.sh - Build and package Krelpin Linux packages from source
# Target focus: aarch64 (primary mobile target), x86_64, armv7h, riscv64
# Enforces Krelpin's own isolated toolchain (Host toolchains disabled by default)
# Manages local pacman binary repository at packages/$ARCH/krelpin.db.tar.zst

set -e

scriptdir="$(cd "$(dirname "$0")" && pwd -P)"
kports_root="$(cd "$scriptdir/.." && pwd -P)"

ARCH="${ARCH:-aarch64}"
REPO_NAME="krelpin"
REBUILD="no"
NODEPS="no"
NOCHECK="yes"
CLEAN="no"
SIGN="no"
ALL_PKGS="no"
SYNC_DEST=""
SYSROOT=""
ALLOW_HOST_TOOLCHAIN="no"
CHROOT_MODE="no"

usage() {
	cat <<EOF
Usage: $0 [options] [package1 package2 ...]

Options:
  -a, --arch <arch>         Target architecture (default: aarch64)
      --sysroot <dir>       Path to Krelpin isolated sysroot (default: sysroot-<arch>)
      --chroot              Build inside an isolated namespace/container (via bwrap)
      --host-toolchain      Allow fallback to host system compiler (NOT recommended)
  -d, --nodeps              Skip dependency checks during build
      --nocheck             Skip running test suites check() (default: enabled for speed)
      --check               Run test suites check()
  -f, --force               Rebuild package even if it already exists in repository
  -c, --clean               Clean build directory (pkg/ and src/) after build
  -s, --sign                Sign package with GPG
      --all                 Build all packages in main/
      --sync-to <dest>      Sync repository to remote mirror (rsync destination)
  -h, --help                Show this help message

Examples:
  $0 bash
  $0 --sysroot /path/to/sysroot-aarch64 coreutils
  $0 --all
  $0 --sync-to user@mirror.krelpin.org:/var/www/mirror/krelpin/
EOF
	exit 0
}

TARGET_PKGS=()
NODEPS="no"

while [ $# -gt 0 ]; do
	case "$1" in
		-a|--arch)
			ARCH="$2"
			shift 2
			;;
		--sysroot)
			SYSROOT="$2"
			shift 2
			;;
		--chroot)
			CHROOT_MODE="yes"
			shift
			;;
		--host-toolchain)
			ALLOW_HOST_TOOLCHAIN="yes"
			shift
			;;
		-d|--nodeps)
			NODEPS="yes"
			shift
			;;
		--nocheck)
			NOCHECK="yes"
			shift
			;;
		--check)
			NOCHECK="no"
			shift
			;;
		-f|--force)
			REBUILD="yes"
			shift
			;;
		-c|--clean)
			CLEAN="yes"
			shift
			;;
		-s|--sign)
			SIGN="yes"
			shift
			;;
		--all)
			ALL_PKGS="yes"
			shift
			;;
		--sync-to)
			SYNC_DEST="$2"
			shift 2
			;;
		-h|--help)
			usage
			;;
		-*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		*)
			TARGET_PKGS+=("$1")
			shift
			;;
	esac
done

REPO_DIR="$kports_root/packages/$ARCH"
mkdir -p "$REPO_DIR"

if [ -z "$SYSROOT" ]; then
	SYSROOT="$kports_root/sysroot-$ARCH"
fi

# Toolchain isolation verification
if [ "$ALLOW_HOST_TOOLCHAIN" != "yes" ]; then
	if [ ! -d "$SYSROOT" ] || [ ! -x "$SYSROOT/usr/bin/gcc" ]; then
		echo "================================================================="
		echo " ERROR: Krelpin isolated toolchain not found at:"
		echo "   $SYSROOT"
		echo ""
		echo " Host system toolchains are strictly prohibited!"
		echo " To build Krelpin's own toolchain (linux-api-headers, glibc, gcc), run:"
		echo "   ./scripts/bootstrap.sh $ARCH"
		echo ""
		echo " (For temporary debugging only, pass --host-toolchain to override)"
		echo "================================================================="
		exit 1
	fi

	echo ">>> Using Krelpin toolchain from: $SYSROOT"
	export PATH="$SYSROOT/usr/bin:$PATH"
	export CC="$SYSROOT/usr/bin/gcc --sysroot=$SYSROOT"
	export CXX="$SYSROOT/usr/bin/g++ --sysroot=$SYSROOT"
	export AR="$SYSROOT/usr/bin/ar"
	export RANLIB="$SYSROOT/usr/bin/ranlib"
	export LD="$SYSROOT/usr/bin/ld --sysroot=$SYSROOT"
	export CFLAGS="--sysroot=$SYSROOT ${CFLAGS:-}"
	export CXXFLAGS="--sysroot=$SYSROOT ${CXXFLAGS:-}"
	export LDFLAGS="--sysroot=$SYSROOT ${LDFLAGS:-}"
	export CPPFLAGS="--sysroot=$SYSROOT ${CPPFLAGS:-}"
	export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
	export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
	export LD_LIBRARY_PATH="/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu:$SYSROOT/usr/lib:${LD_LIBRARY_PATH:-}"
fi

# Point makepkg to sysroot pacman so dependency checks evaluate against Krelpin's sysroot
if [ -f "$SYSROOT/etc/pacman.conf" ]; then
	PACMAN_WRAPPER="$(mktemp -t krelpin-pacman.XXXXXX)"
	cat << EOF > "$PACMAN_WRAPPER"
#!/bin/sh
exec pacman --config "$SYSROOT/etc/pacman.conf" --root "$SYSROOT" "\$@"
EOF
	chmod +x "$PACMAN_WRAPPER"
	trap 'rm -f "$PACMAN_WRAPPER"' EXIT
	export PACMAN="$PACMAN_WRAPPER"
fi

# Ensure local packaging utilities (makepkg, repo-add) are accessible
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
[ -d "$HOME/.local/lib" ] && export LIBRARY_PATH="$HOME/.local/lib:${LIBRARY_PATH:-}"
[ -d "$HOME/.local/lib" ] && export LD_LIBRARY_PATH="$HOME/.local/lib:${LD_LIBRARY_PATH:-}"

if [ -n "$SYNC_DEST" ] && [ ${#TARGET_PKGS[@]} -eq 0 ] && [ "$ALL_PKGS" != "yes" ]; then
	echo ">>> Syncing Krelpin $ARCH repository to $SYNC_DEST..."
	rsync -avzP --delete "$REPO_DIR/" "$SYNC_DEST/$ARCH/"
	echo ">>> Repository synchronized successfully."
	exit 0
fi

if [ "$ALL_PKGS" = "yes" ]; then
	TARGET_PKGS=()
	for pdir in "$kports_root"/main/*; do
		[ -d "$pdir" ] || continue
		[ -f "$pdir/PKGBUILD" ] || continue
		TARGET_PKGS+=("$(basename "$pdir")")
	done
fi

if [ ${#TARGET_PKGS[@]} -eq 0 ]; then
	echo "Error: No package specified to build." >&2
	echo "Run '$0 --help' for usage." >&2
	exit 1
fi

echo "================================================================="
echo " Krelpin Linux Package Builder"
echo " Architecture : $ARCH"
echo " Sysroot      : $SYSROOT"
echo " Repository   : $REPO_DIR"
echo " Packages     : ${TARGET_PKGS[*]}"
echo "================================================================="

for pkg in "${TARGET_PKGS[@]}"; do
	pkg_clean="${pkg##*/}"
	pkg_dir=""

	if [ -d "$kports_root/main/$pkg_clean" ]; then
		pkg_dir="$kports_root/main/$pkg_clean"
	elif [ -d "$pkg" ]; then
		pkg_dir="$pkg"
	else
		echo "Error: PKGBUILD not found for '$pkg' in main/ directory." >&2
		exit 1
	fi

	if [ ! -f "$pkg_dir/PKGBUILD" ]; then
		echo "Error: $pkg_dir/PKGBUILD does not exist." >&2
		exit 1
	fi

	echo ""
	echo ">>> Building [$pkg_clean] for $ARCH..."

	cd "$pkg_dir"

	# Build makepkg arguments
	MAKEPKG_ARGS=("-f" "--skippgpcheck")
	[ "$NODEPS" = "yes" ] && MAKEPKG_ARGS+=("-d")
	[ "$NOCHECK" = "yes" ] && MAKEPKG_ARGS+=("--nocheck")
	[ "$SIGN" = "yes" ] && MAKEPKG_ARGS+=("--sign")

	# Check if package already exists in repository
	if [ "$REBUILD" != "yes" ]; then
		existing_pkg=$(find "$REPO_DIR" -name "${pkg_clean}-[0-9]*.pkg.tar.*" | head -n1 || true)
		if [ -n "$existing_pkg" ]; then
			echo "Package $pkg_clean already exists in $REPO_DIR: $(basename "$existing_pkg")"
			echo "Use -f / --force to force rebuild."
			continue
		fi
	fi

	# Run makepkg in isolated environment
	if [ "$CHROOT_MODE" = "yes" ] && command -v bwrap >/dev/null 2>&1; then
		echo ">>> Executing build inside isolated namespace container (bwrap)..."
		bwrap --ro-bind "$SYSROOT" / \
			--bind "$pkg_dir" "$pkg_dir" \
			--proc /proc \
			--dev /dev \
			--tmpfs /tmp \
			--dir "$HOME" \
			--chdir "$pkg_dir" \
			CARCH="$ARCH" CARCH_TARGET="$ARCH" makepkg "${MAKEPKG_ARGS[@]}"
	else
		CARCH="$ARCH" CARCH_TARGET="$ARCH" makepkg "${MAKEPKG_ARGS[@]}"
	fi

	# Find generated packages
	pkg_files=(*.pkg.tar.*)
	if [ ! -e "${pkg_files[0]}" ]; then
		echo "Error: makepkg completed but no .pkg.tar.* package found for $pkg_clean!" >&2
		exit 1
	fi

	for pkgfile in *.pkg.tar.*; do
		[ -f "$pkgfile" ] || continue
		# Ignore signature files in loop
		case "$pkgfile" in
			*.sig) continue ;;
		esac

		echo ">>> Moving $pkgfile -> $REPO_DIR/"
		mv -f "$pkgfile" "$REPO_DIR/"
		[ -f "$pkgfile.sig" ] && mv -f "$pkgfile.sig" "$REPO_DIR/"

		echo ">>> Registering $pkgfile in $REPO_NAME database..."
		repo-add "$REPO_DIR/${REPO_NAME}.db.tar.zst" "$REPO_DIR/$pkgfile"

		if [ -d "$SYSROOT" ] && [ -f "$SYSROOT/etc/pacman.conf" ]; then
			echo ">>> Installing $pkgfile into sysroot ($SYSROOT)..."
			fakeroot pacman --config "$SYSROOT/etc/pacman.conf" -U --noconfirm --root "$SYSROOT" --overwrite '*' -dd "$REPO_DIR/$pkgfile" 2>/dev/null || true
		fi
	done

	# Clean build artifacts if requested
	if [ "$CLEAN" = "yes" ]; then
		rm -rf src/ pkg/
	fi

	# Update database symlinks
	ln -sf "${REPO_NAME}.db.tar.zst" "$REPO_DIR/${REPO_NAME}.db"
	ln -sf "${REPO_NAME}.files.tar.zst" "$REPO_DIR/${REPO_NAME}.files"

	echo ">>> Successfully built and registered: $pkg_clean ($ARCH)"
done

echo ""
echo "================================================================="
echo " Build summary:"
echo " Repository database: $REPO_DIR/${REPO_NAME}.db.tar.zst"
echo " Total packages in repo:"
ls -lh "$REPO_DIR"/*.pkg.tar.* 2>/dev/null || echo "No packages in repo."
echo "================================================================="

if [ -n "$SYNC_DEST" ]; then
	echo ""
	echo ">>> Syncing repository to mirror: $SYNC_DEST..."
	rsync -avzP "$REPO_DIR/" "$SYNC_DEST/$ARCH/"
	echo ">>> Mirror sync complete."
fi
