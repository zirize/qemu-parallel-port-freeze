#!/bin/bash
# XP 실기 LPT A/B 하니스.
#
# 막히는 싱크(stall-sink.py)를 9100 에 띄우고, XP 를 snapshot=on 으로 올린 뒤
# monitor 로 키를 주입해 cmd 에서 `copy /b <파일> lpt1:` 을 돌린다.
# 그 동안 monitor 왕복(info status)을 1초 간격으로 찍어 QEMU 가 살아 있는지 본다.
#
# 사용법: lpt-xp.sh <태그> <qemu 바이너리> [정체시간초]
#   전:  lpt-xp.sh before <패치-전-qemu>
#   후:  lpt-xp.sh after  <패치-후-qemu>
#
# 원본 이미지는 snapshot=on 으로만 연다. 절대 빼지 말 것.
set -u

TAG="${1:?태그}"
BIN="${2:?qemu 바이너리}"
STALL="${3:-90}"

HERE="$(dirname "$(readlink -f "$0")")"
OUT="${LPT_XP_OUT:-/tmp/lpt-xp}"
mkdir -p "$OUT"
WORK_DIR="${WORK_DIR:?WORK_DIR 에 images/ 를 담은 디렉토리를 지정할 것}"
MON="$OUT/$TAG-mon.sock"
PORT="${LPT_XP_PORT:-9100}"

rm -f "$MON"

# 싱크 종류. socket 은 실제 CUPS 경로에 가깝지만 커널 소켓 버퍼가 수 MB 를
# 먹어 주므로 막히기까지 오래 걸린다(관측: XP 의 LPT 출력은 ~8KB/s, 송신
# 버퍼는 tcp_wmem 상한 4MB 까지 자란다). pipe 는 FIFO 버퍼가 64KB 라 몇 초
# 만에 EAGAIN 에 도달한다 — 같은 기전을 빨리 재현하려면 이쪽.
SINK_KIND="${LPT_XP_SINK:-pipe}"

if [ "$SINK_KIND" = socket ]; then
    echo "[$TAG] 소켓 싱크 기동 (정체 최대 ${STALL}초, 포트 $PORT)"
    python3 "$HERE/stall-sink.py" "$STALL" "$OUT/$TAG-lpt-out.bin" "$PORT" \
        > "$OUT/$TAG-sink.log" 2>&1 &
    SINK=$!
    CHARDEV="socket,id=lpt,host=127.0.0.1,port=$PORT"
else
    FIFO="$OUT/$TAG-fifo"
    rm -f "$FIFO.in" "$FIFO.out"
    mkfifo "$FIFO.in" "$FIFO.out"
    echo "[$TAG] pipe 싱크: $FIFO.out (아무도 읽지 않는다. 64KB 차면 막힌다)"
    echo "[$TAG] 배수하려면: cat $FIFO.out > $OUT/$TAG-lpt-out.bin &"
    SINK=-
    CHARDEV="pipe,id=lpt,path=$FIFO"
fi

echo "[$TAG] XP 기동: $BIN"
"$BIN" -name "winxp_lpttest" \
    -M "q35,usb=on,acpi=on,hpet=off" \
    -global "q35-pcihost.x-pci-hole64-fix=false" \
    -m 2048 -cpu host -accel kvm \
    -display none \
    -netdev "vde,id=network0,sock=/tmp/vde0" \
    -device "virtio-net-pci,netdev=network0" \
    -monitor "unix:$MON,server,nowait" \
    -rtc "base=localtime,clock=host" \
    -serial none \
    -chardev "$CHARDEV" \
    -parallel "chardev:lpt" \
    -drive "if=virtio,file=$WORK_DIR/images/xp.qcow2,snapshot=on" \
    -drive "if=virtio,file=$WORK_DIR/images/xp_data.qcow2,snapshot=on" \
    > "$OUT/$TAG.out" 2> "$OUT/$TAG.err" &
QEMU=$!
echo "$QEMU" > "$OUT/$TAG.pid"
echo "[$TAG] qemu pid=$QEMU, monitor=$MON, sink pid=$SINK"
