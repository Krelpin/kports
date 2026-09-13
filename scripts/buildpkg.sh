#!/bin/bash
# buildpkg.sh - Build and package Krelpin Linux packages from source
# Target focus: aarch64 (primary mobile target), x86_64, armv7h, riscv64
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

# Setup environment for local tools and libraries
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
[ -d "$HOME/.local/lib" ] && export LIBRARY_PATH="$HOME/.local/lib:${LIBRARY_PATH:-}"
[ -d "$HOME/.local/lib" ] && export LD_LIBRARY_PATH="$HOME/.local/lib:${LD_LIBRARY_PATH:-}"

usage() {
	cat <<EOF
Usage: $0 [options] [package1 package2 ...]

Options:
  -a, --arch <arch>      Target architecture (default: aarch64)
  -d, --nodeps           Skip dependency checks during build (useful during bootstrap)
      --nocheck          Skip running test suites check() (default: enabled for speed)
      --check            Run test suites check()
  -f, --force            Rebuild package even if it already exists in repository
  -c, --clean            Clean build directory (pkg/ and src/) after build
  -s, --sign             Sign package with GPG
      --all              Build all packages in main/
      --sync-to <dest>   Sync repository to remote mirror (rsync destination)
  -h, --help             Show this help message

Examples:
  $0 bash
  $0 --nodeps glibc gcc binutils
  $0 --all
  $0 --sync-to user@mirror.krelpin.org:/var/www/mirror/krelpin/
EOF
	exit 0
}

TARGET_PKGS=()

while [ $# -gt 0 ]; do
	case "$1" in
		-a|--arch)
			ARCH="$2"
			shift 2
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

	# Run makepkg
	CARCH="$ARCH" CARCH_TARGET="$ARCH" makepkg "${MAKEPKG_ARGS[@]}"

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
