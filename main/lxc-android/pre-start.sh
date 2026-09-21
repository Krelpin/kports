#!/bin/sh

mkdir -p /dev/__properties__
mkdir -p /dev/socket

# mount binderfs if needed
if [ ! -e /dev/binder ]; then
    mkdir -p /dev/binderfs
    mount -t binder binder /dev/binderfs -o stats=global
    chmod 666 /dev/binderfs/*binder
    ln -s /dev/binderfs/*binder /dev
fi
