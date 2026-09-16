#!/bin/bash
# 최소 리눅스 게스트로 LPT 레지스터를 직접 때리고 트레이스를 받는다.
# 사용법: lpt-linux.sh <태그> [프로브]
#   프로브: detect | negotiate | spin | print | one | idle | driver | flood | irq | shell
#           (쉼표로 나열 가능)
# HMP 모니터가 logs/<태그>-mon.sock 에 열린다. 「호스트가 갇혔는지」는 이걸로 가른다:
#   echo info status | socat -T5 - UNIX-CONNECT:logs/<태그>-mon.sock
# 결과: logs/<태그>-lpt-trace.log   레지스터 접근
#       logs/<태그>-lpt-out.bin     실제 출력 바이트
#       logs/<태그>-serial.log      게스트 콘솔
set -u
TAG="${1:?태그}"
PROBE="${2:-detect,negotiate,print}"
ROOT="$(dirname "$(readlink -f "$0")")/.."
BIN="${LPT_BIN:?LPT_BIN 에 시험할 qemu-system-i386 경로를 지정할 것}"
MACH="${MACH:-q35}"
TMO="${TMO:-180}"

TRACE_ARGS=(-trace "parallel_ioport_*" -D "$ROOT/logs/$TAG-lpt-trace.log")
[ -n "${NOTRACE:-}" ] && TRACE_ARGS=()

mkdir -p "$ROOT/logs"
: > "$ROOT/logs/$TAG-lpt-out.bin"
rm -f "$ROOT/logs/$TAG-mon.sock"

# 어떤 바이너리로 돌렸는지 반드시 남긴다. 공용 빌드 디렉토리는 다른 세션이
# 런 사이에 교체할 수 있고, 그러면 A/B 가 조용히 오염된다.
BIN_VER="$("$BIN" --version 2>/dev/null | head -1)"
BIN_SUM="$(sha256sum "$BIN" 2>/dev/null | cut -c1-16)"
BIN_MTIME="$(stat -c%y "$BIN" 2>/dev/null | cut -d. -f1)"
{
  echo "### $BIN"
  echo "###   $BIN_VER"
  echo "###   sha256:$BIN_SUM  mtime:$BIN_MTIME"
  echo "### -M $MACH / probe=$PROBE / chardev=${LPT_CHARDEV:-file}"
} | tee "$ROOT/logs/$TAG-binary.txt"

timeout "$TMO" "$BIN" -name lpt_linux \
    -M "$MACH" -m 512 -cpu host -accel kvm \
    -display none -vga none -net none \
    -monitor "unix:$ROOT/logs/$TAG-mon.sock,server,nowait" \
    -kernel "$ROOT/guest/vmlinuz-lts" \
    -initrd "$ROOT/guest/initramfs.cpio.gz" \
    -append "console=ttyS0,115200 probe=$PROBE floodn=${FLOODN:-64} irqn=${IRQN:-32} panic=5 loglevel=4" \
    -chardev "${LPT_CHARDEV:-file,id=lptfile,path=$ROOT/logs/$TAG-lpt-out.bin}" \
    -parallel "chardev:lptfile" \
    -serial stdio \
    "${TRACE_ARGS[@]}" 2>&1 | tee "$ROOT/logs/$TAG-serial.log"

echo
echo "--- 트레이스 요약 ---"
if [ -s "$ROOT/logs/$TAG-lpt-trace.log" ]; then
    echo "총 접근: $(wc -l < "$ROOT/logs/$TAG-lpt-trace.log") 건"
    echo "읽기 값 분포:"
    grep 'parallel_ioport_read' "$ROOT/logs/$TAG-lpt-trace.log" \
        | sed -n 's/.*addr \(0x[0-9a-f]*\) val \(0x[0-9a-f]*\).*/  addr \1 val \2/p' \
        | sort | uniq -c | sort -rn | head
    echo "쓰기 값 분포:"
    grep 'parallel_ioport_write' "$ROOT/logs/$TAG-lpt-trace.log" \
        | sed -n 's/.*addr \(0x[0-9a-f]*\) val \(0x[0-9a-f]*\).*/  addr \1 val \2/p' \
        | sort | uniq -c | sort -rn | head
else
    echo "트레이스 없음 (0 건)"
fi
echo "출력 바이트: $(stat -c%s "$ROOT/logs/$TAG-lpt-out.bin") 바이트"
