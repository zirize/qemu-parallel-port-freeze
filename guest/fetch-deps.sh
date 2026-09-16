#!/bin/bash
# 게스트 구성에 필요한 외부 바이너리를 내려받는다. 저장소에는 담지 않는다.
#   vmlinuz-lts    Alpine x86(32비트) 커널. CONFIG_DEVPORT=y, 8250 콘솔 내장.
#   busybox-i686   정적 busybox. initramfs 의 유일한 유저랜드.
#   modloop-lts    같은 커널용 모듈 squashfs. parport_pc / lp / ppdev 를 꺼낸다.
set -eu
G="$(dirname "$(readlink -f "$0")")"
ALPINE="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86/netboot"
BB="https://busybox.net/downloads/binaries/1.35.0-i686-linux-musl/busybox"

cd "$G"
[ -f vmlinuz-lts  ] || { echo "커널 받는 중..."; curl -fsS -o vmlinuz-lts "$ALPINE/vmlinuz-lts"; }
[ -f busybox-i686 ] || { echo "busybox 받는 중..."; curl -fsS -o busybox-i686 "$BB"; chmod +x busybox-i686; }
[ -f modloop-lts  ] || { echo "modloop 받는 중 (172MB)..."; curl -fsS -o modloop-lts "$ALPINE/modloop-lts"; }

if [ ! -d mods ] || [ -z "$(ls -A mods 2>/dev/null)" ]; then
    echo "모듈 추출 중..."
    command -v unsquashfs >/dev/null || { echo "unsquashfs 필요: apt install squashfs-tools"; exit 1; }
    T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
    unsquashfs -q -d "$T" -f modloop-lts \
        'modules/*/kernel/drivers/parport/*' \
        'modules/*/kernel/drivers/char/lp.ko' \
        'modules/*/kernel/drivers/char/ppdev.ko' >/dev/null
    mkdir -p mods
    for m in parport parport_pc lp ppdev; do
        f=$(find "$T" -name "$m.ko" | head -1)
        [ -n "$f" ] && cp "$f" mods/
    done
fi

echo "준비 완료:"
ls -la vmlinuz-lts busybox-i686 modloop-lts
ls -la mods/
echo
echo "다음: ./build-initramfs.sh"
