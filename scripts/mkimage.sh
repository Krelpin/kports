#!/bin/sh

# mkimage.sh - Tool for building bootable images & rootfs for Krelpin Linux
# Architecture focus: aarch64 (primary mobile target), x86_64, armv7, riscv64
# Package system: pacman + glibc

set -e

scriptdir="$(dirname "$0")"

# Source helper functions
if [ -e "$scriptdir/functions.sh" ]; then
	. "$scriptdir/functions.sh"
elif [ -e "${ABUILD_SHAREDIR:-/usr/share/abuild}/functions.sh" ]; then
	. "${ABUILD_SHAREDIR:-/usr/share/abuild}/functions.sh"
fi

git=$(command -v git 2>/dev/null) || git=true

set_source_date() {
	if ! $git rev-parse --show-toplevel >/dev/null 2>&1; then
		git=true
	fi
	if [ -z "$SOURCE_DATE_EPOCH" ] && [ "$($git -C "$scriptdir" status -s 2>/dev/null | wc -l)" -ne 0 ]; then
		SOURCE_DATE_EPOCH=$($git -C "$scriptdir" log -1 --format=%cd --date=unix 2>/dev/null || true)
	fi
	if [ -z "$SOURCE_DATE_EPOCH" ]; then
		SOURCE_DATE_EPOCH=$(date -u "+%s")
	fi
	export SOURCE_DATE_EPOCH
}

set_source_date

all_sections=""
all_profiles=""
all_checksums="sha256 sha512"
all_dirs=""
build_date="$(date -u +%y%m%d -d "@$SOURCE_DATE_EPOCH")"

# Mobile-first default: aarch64 (with multi-architecture support)
default_arch="${DEFAULT_ARCH:-aarch64}"
distro_name="krelpin"

_hostkeys=""
_simulate=""
_checksum=""
_yaml=""

OUTDIR="$PWD"
RELEASE="${build_date}"

msg() {
	if [ -n "$quiet" ]; then return 0; fi
	local prompt="${GREEN}>>>${NORMAL}"
	local name="${BLUE}mkimage${ARCH+-$ARCH}${NORMAL}"
	printf "${prompt} ${name}: %s\n" "$1" >&2
}

warning() {
	local prompt="${YELLOW}>>> WARNING:${NORMAL}"
	printf "${prompt} %s\n" "$*" >&2
}

error() {
	local prompt="${RED}>>> ERROR:${NORMAL}"
	printf "${prompt} %s\n" "$*" >&2
}

die() {
	error "$@"
	exit 1
}

list_has() {
	local needle="$1"
	local i
	shift
	for i in "$@"; do
		[ "$needle" != "$i" ] || return 0
	done
	return 1
}

usage() {
	cat <<EOF

$0	[--tag RELEASE] [--outdir OUTDIR] [--workdir WORKDIR]
		[--arch ARCH] [--profile PROFILE] [--format FORMAT]
		[--hostkeys] [--simulate]
		[--repository REPO [--repository REPO]]
		[--repositories-file REPO_FILE] [--yaml]
$0	--help

options:
--arch			Specify target architecture: aarch64 (mobile primary), x86_64, armv7, riscv64
			(default: $default_arch)
--profile		Specify which profiles to build (default: standard)
--format		Image output format: rootfs (default), img (raw disk), iso (hybrid ISO)
--hostkeys		Copy system pacman/gnupg signing keys to created images
--outdir		Specify directory for the created images (default: $OUTDIR)
--repositories-file	List of repositories / pacman.conf to use for the image create
--repository		Package repository URL or path to use for the image create
--simulate		Don't execute commands
--tag			Build images for tag RELEASE (default: $RELEASE)
--workdir		Specify temporary working directory (cache)
--yaml			Write YAML metadata file (latest-releases.yaml)

known profiles: $(echo $all_profiles | tr ' ' '\n' | sort -u | tr '\n' ' ')

EOF
}

load_plugins() {
	local f
	[ -d "$1" ] || return 0
	for f in "$1"/mkimg.*.sh; do
		[ -e "$f" ] || return 0
		break
	done
	all_profiles="$all_profiles $(sed -n -e 's/^profile_\(.*\)() {$/\1/p' "$1"/mkimg.*.sh 2>/dev/null)"
	all_sections="$all_sections $(sed -n -e 's/^section_\(.*\)() {$/\1/p' "$1"/mkimg.*.sh 2>/dev/null)"
	for f in "$1"/mkimg.*.sh; do
		. "$f"
	done
}

checksum() {
	sha1sum | cut -f 1 -d ' '
}

build_section() {
	local section="$1"
	local args="$*"
	local _dir
	_dir=$(echo "$args" | tr -c 'a-zA-Z0-9' '_')
	shift
	local args="$*"

	if [ -z "$_dir" ]; then
		return 1
	fi

	if [ ! -e "$WORKDIR/${_dir}" ]; then
		DESTDIR="$WORKDIR/${_dir}.work"
		msg "--> $section $args"
		if [ -z "$_simulate" ]; then
			rm -rf "$DESTDIR"
			mkdir -p "$DESTDIR"
			build_${section} "$@"
			mv "$DESTDIR" "$WORKDIR/${_dir}"
			_dirty="yes"
		fi
	fi
	unset DESTDIR
	all_dirs="$all_dirs $_dir"
	_my_sections="$_my_sections $_dir"
}

build_profile() {
	local _id _dir _spec
	_my_sections=""
	_dirty="no"

	profile_$PROFILE
	list_has "$ARCH" $arch || return 0

	msg "Building $PROFILE ($ARCH)"

	# Collect list of needed sections, and make sure they are built
	for SECTION in $all_sections; do
		section_$SECTION
	done

	# Defaults
	[ -n "$image_name" ] || image_name="${distro_name}-${PROFILE}"
	[ -n "$output_filename" ] || output_filename="${image_name}-${RELEASE}-${ARCH}.${image_ext}"
	local output_file="${OUTDIR:-.}/$output_filename"

	# Construct final image filesystem
	local _imgid
	_imgid=$(echo -n "$_my_sections" | tr ' ' '\n' | sort | tr '\n' ' ' | checksum)
	DESTDIR="$WORKDIR/image-$_imgid-$ARCH-$PROFILE"
	if [ "$_dirty" = "yes" ] || [ ! -e "$DESTDIR" ]; then
		msg "Creating $output_filename"
		if [ -z "$_simulate" ]; then
			# Merge sections
			rm -rf "$DESTDIR"
			mkdir -p "$DESTDIR"
			for _dir in $_my_sections; do
				for _fn in "$WORKDIR/$_dir"/*; do
					[ ! -e "$_fn" ] || cp -Lrs "$_fn" "$DESTDIR"/
				done
			done
			echo "${distro_name}-${PROFILE}-${RELEASE} ${build_date}" > "$DESTDIR"/.krelpin-release
		fi
	fi

	if [ "$_dirty" = "yes" ] || [ ! -e "$output_file" ]; then
		# Create image
		[ -n "$output_format" ] || output_format="${image_ext//[:\.]/}"
		create_image_${output_format}

		if [ "$_checksum" = "yes" ]; then
			for _c in $all_checksums; do
				echo "$(${_c}sum "$output_file" | cut -d' ' -f1)  ${output_filename}" > "${output_file}.${_c}"
			done
		fi
	fi
	if [ -n "$_yaml_out" ]; then
		"$mkimage_yaml" --release "$RELEASE" \
			--title "$title" \
			--desc "$desc" \
			"$output_file" >> "$_yaml_out"
	fi
}

# load plugins
load_plugins "$scriptdir"
if [ -n "$HOME" ]; then
	load_plugins "$HOME/.mkimage"
fi

mkimage_yaml="$scriptdir/mkimage-yaml.sh"

# parse parameters
while [ $# -gt 0 ]; do
	opt="$1"
	shift
	case "$opt" in
	--repositories-file) REPOS_FILE="$1"; shift ;;
	--repository)
		if [ -z "$REPOS" ]; then
			REPOS="$1"
		else
			REPOS=$(printf '%s\n%s' "$REPOS" "$1");
		fi
		shift ;;
	--extra-repository)
		warning "--extra-repository is deprecated. Use multiple --repository"
		EXTRAREPOS="$EXTRAREPOS $1"
		shift ;;
	--workdir) WORKDIR="$1"; shift ;;
	--outdir) OUTDIR="$1"; shift ;;
	--tag) RELEASE="$1"; shift ;;
	--arch) req_arch="$1"; shift ;;
	--profile) req_profiles="$1"; shift ;;
	--format) IMAGE_FORMAT="$1"; export IMAGE_FORMAT; shift ;;
	--hostkeys) _hostkeys="--hostkeys";;
	--simulate) _simulate="yes";;
	--checksum) _checksum="yes";;
	--yaml) _yaml="yes";;
	--help) usage; exit 0;;
	--) break ;;
	-*) usage; exit 1;;
	esac
done

if [ -z "$RELEASE" ]; then
	if $git describe --exact-match >/dev/null 2>&1; then
		RELEASE=$($git describe --always)
		RELEASE=${RELEASE#v}
	else
		RELEASE="${build_date}"
	fi
fi

if [ -z "$REPOS" ] && [ -z "$REPOS_FILE" ]; then
	# Default local/workspace fallback if no remote repo given
	REPOS_FILE="$scriptdir/../pacman.conf"
	if [ ! -f "$REPOS_FILE" ]; then
		REPOS="file:///var/cache/pacman/pkg"
	fi
fi

# setup defaults
if [ -z "$WORKDIR" ]; then
	WORKDIR="$(mktemp -d -t mkimage.XXXXXX)"
	trap 'rm -rf "$WORKDIR"' INT EXIT
fi

req_profiles=${req_profiles:-${all_profiles:-standard}}
req_arch=${req_arch:-${default_arch}}
[ "$req_arch" != "all" ] || req_arch="aarch64 x86_64 armv7 riscv64"
[ "$req_profiles" != "all" ] || req_profiles="${all_profiles:-standard}"

mkdir -p "$OUTDIR"

# pacman key / gnupg key
_pub=${PACKAGER_PRIVKEY:+${PACKAGER_PRIVKEY}.pub}
_packager_pubkey="${PACKAGER_PUBKEY:-$_pub}"

# create images for each requested architecture
for ARCH in $req_arch; do
	PACROOT="$WORKDIR/pacroot-$ARCH"
	APKROOT="$PACROOT"
	export PACROOT APKROOT

	PACCONF="$WORKDIR/pacman-$ARCH.conf"
	export PACCONF

	if [ ! -e "$PACROOT" ]; then
		mkdir -p "$PACROOT/var/cache/pacman/pkg" "$PACROOT/var/lib/pacman" "$PACROOT/etc/pacman.d/gnupg"

		if [ -n "$_hostkeys" ] && [ -d /etc/pacman.d/gnupg ]; then
			cp -a /etc/pacman.d/gnupg/* "$PACROOT/etc/pacman.d/gnupg/" 2>/dev/null || true
		fi
		if [ -n "$_packager_pubkey" ]; then
			cp "$_packager_pubkey" "$PACROOT/etc/pacman.d/gnupg/" 2>/dev/null || true
		fi

		# Generate pacman.conf for this architecture with Krelpin repositories
		cat > "$PACCONF" <<-EOF
		[options]
		Architecture = $ARCH
		DBPath = $PACROOT/var/lib/pacman
		CacheDir = $PACROOT/var/cache/pacman/pkg
		GPGDir = $PACROOT/etc/pacman.d/gnupg
		HoldPkg = pacman glibc
		SigLevel = Never
		LocalFileSigLevel = Optional

		[krelpin]
		SigLevel = Never

		[main]
		SigLevel = Never

		EOF

		if [ -n "$REPOS_FILE" ] && [ -f "$REPOS_FILE" ]; then
			cat "$REPOS_FILE" >> "$PACCONF"
		fi

		if [ -n "$REPOS" ]; then
			echo "$REPOS" | while IFS= read -r repo_line; do
				[ -n "$repo_line" ] || continue
				if echo "$repo_line" | grep -q '^\['; then
					echo "$repo_line" >> "$PACCONF"
				else
					cat >> "$PACCONF" <<-EOF
					Server = $repo_line
					EOF
				fi
			done
		fi

		for repo in $EXTRAREPOS; do
			cat >> "$PACCONF" <<-EOF
			[extra_repo]
			Server = $repo
			SigLevel = Never

			EOF
		done
	fi

	# Synchronize repositories if pacman available
	if command -v pacman >/dev/null 2>&1; then
		pacman --config "$PACCONF" -Sy 2>/dev/null || true
	fi

	if [ "$_yaml" = "yes" ]; then
		_yaml_out="${OUTDIR:-.}/latest-releases.yaml"
		echo "---" > "$_yaml_out"
	fi
	for PROFILE in $req_profiles; do
		(set -eo pipefail; build_profile)
	done
done
echo "Krelpin images generated in $OUTDIR"
