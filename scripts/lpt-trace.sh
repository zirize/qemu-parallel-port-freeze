#!/bin/bash
# LPT 레지스터 접근을 추적한다. 디스크는 snapshot=on.
# 사용법: lpt-trace.sh <태그>
set -u
TAG="${1:?태그}"
ROOT="$(dirname "$(readlink -f "$0")")/.."
WORK_DIR="${WORK_DIR:?WORK_DIR 에 images/ 를 담은 디렉토리를 지정할 것}"
MON="/tmp/qemu_lpt_probe"
BIN="${LPT_BIN:?LPT_BIN 에 시험할 qemu-system-i386 경로를 지정할 것}"

echo quit | timeout 5 socat - UNIX-CONNECT:"$MON" >/dev/null 2>&1; sleep 4; rm -f "$MON"

exec "$BIN" -name lpt_probe \
    -M "q35,usb=on,acpi=on,hpet=off" \
    -global "q35-pcihost.x-pci-hole64-fix=false" \
    -m 2048 -cpu host -accel kvm \
    -netdev "vde,id=network0,sock=/tmp/vde0" \
    -device "virtio-net-pci,netdev=network0" \
    -display "sdl" -vga cirrus \
    -audiodev "pipewire,id=pw0" -device "AC97,audiodev=pw0" \
    -monitor "unix:$MON,server,nowait" \
    -rtc "base=localtime,clock=host" \
    -serial none \
    -chardev "file,id=lptfile,path=$ROOT/logs/$TAG-lpt-out.bin" \
    -parallel "chardev:lptfile" \
    -drive "if=virtio,file=$WORK_DIR/images/xp.qcow2,snapshot=on" \
    -drive "if=virtio,file=$WORK_DIR/images/xp_data.qcow2,snapshot=on" \
    -trace "parallel_ioport_*" \
    -D "$ROOT/logs/$TAG-lpt-trace.log"
