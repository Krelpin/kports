#!/bin/sh

# Common helper functions for kports scripts

# Ensure local tools are in PATH
export PATH="$HOME/.local/bin:${scriptdir:-.}/../bin:$PATH"

# Terminal colors
if [ -t 1 ] || [ -t 2 ]; then
	NORMAL="\033[1;0m"
	STRONG="\033[1;1m"
	RED="\033[1;31m"
	GREEN="\033[1;32m"
	YELLOW="\033[1;33m"
	BLUE="\033[1;34m"
else
	NORMAL=""
	STRONG=""
	RED=""
	GREEN=""
	YELLOW=""
	BLUE=""
fi

msg() {
	local prompt="${GREEN}>>>${NORMAL}"
	printf "${prompt} %s\n" "$*" >&2
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

# Host architecture detection
CBUILD_ARCH="${CBUILD_ARCH:-$(uname -m)}"
case "$CBUILD_ARCH" in
	x86_64)
		CBUILD="${CBUILD:-x86_64-pc-linux-gnu}"
		;;
	aarch64|arm64)
		CBUILD_ARCH="aarch64"
		CBUILD="${CBUILD:-aarch64-unknown-linux-gnu}"
		;;
	armv7l|armv7)
		CBUILD_ARCH="armv7"
		CBUILD="${CBUILD:-armv7l-unknown-linux-gnueabihf}"
		;;
	riscv64)
		CBUILD="${CBUILD:-riscv64-unknown-linux-gnu}"
		;;
	i686|i386|x86)
		CBUILD_ARCH="x86"
		CBUILD="${CBUILD:-i686-pc-linux-gnu}"
		;;
	*)
		CBUILD="${CBUILD:-$(uname -m)-pc-linux-gnu}"
		;;
esac

CHOST="${CHOST:-$CBUILD}"
CARCH="${CARCH:-$CBUILD_ARCH}"
