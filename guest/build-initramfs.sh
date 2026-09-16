#!/bin/bash
# busybox 하나짜리 initramfs 를 만든다. 결과: guest/initramfs.cpio.gz
set -eu
G="$(dirname "$(readlink -f "$0")")"
B="${TMPDIR:-/tmp}/lpt-initramfs-build.$$"
trap 'rm -rf "$B"' EXIT

mkdir -p "$B"/{bin,dev,proc,sys}
cp "$G/busybox-i686" "$B/bin/busybox"
chmod 755 "$B/bin/busybox"
if [ -d "$G/mods" ]; then
    mkdir -p "$B/lib/modules"
    cp "$G"/mods/*.ko "$B/lib/modules/"
fi
cp "$G/init" "$B/init"
chmod 755 "$B/init"

( cd "$B" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$G/initramfs.cpio.gz"
echo "생성: $G/initramfs.cpio.gz  ($(stat -c%s "$G/initramfs.cpio.gz") 바이트)"
