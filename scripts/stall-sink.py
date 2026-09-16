#!/usr/bin/env python3
"""LPT 재현용 '막히는 싱크'.

127.0.0.1:9100 에서 듣다가 연결을 받아 놓고 STALL 초 동안 recv 를 하지 않는다.
수신 버퍼가 차면 보내는 쪽(QEMU)의 write 가 EAGAIN 을 내기 시작한다 —
패치 전 QEMU 는 여기서 BQL 을 쥔 채 g_usleep(100) 루프에 갇힌다.

STALL 초가 지나면 남은 것을 전부 빨아들이고 총 바이트를 센다.
그 수가 게스트가 보낸 양과 맞으면 '배압·보존', 모자라면 '버림'이다.

사용법: stall-sink.py <최대정체초> <출력파일> [포트]
       <출력파일>.drain 파일을 만들면 그 즉시 드레인을 시작한다.
"""
import os
import socket
import sys
import time

stall = int(sys.argv[1])
out_path = sys.argv[2]
port = int(sys.argv[3]) if len(sys.argv) > 3 else 9100
trigger = out_path + ".drain"
try:
    os.unlink(trigger)
except OSError:
    pass

t0 = time.time()


def log(msg):
    print("[%7.2f] %s" % (time.time() - t0, msg), flush=True)


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
# 수신 버퍼를 작게 잡아 두면 몇 KB 만에 상대가 막힌다. 8MB 를 밀어 넣을
# 때까지 기다릴 필요가 없다.
srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
srv.bind(("127.0.0.1", port))
srv.listen(1)
log("listen 127.0.0.1:%d, rcvbuf=%d" % (port, srv.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)))

conn, addr = srv.accept()
log("accept %s:%d — 이제 읽지 않는다 (최대 %d초, 트리거: %s)"
    % (addr[0], addr[1], stall, trigger))

# 게스트가 실제로 밀어내기 시작하는 시점은 우리가 정한다(부팅·타이핑 시간이
# 들쭉날쭉하므로). 트리거 파일이 생기거나 stall 초가 지나면 드레인한다.
end = time.time() + stall
while time.time() < end:
    if os.path.exists(trigger):
        log("트리거 감지 — 드레인으로 넘어간다")
        break
    time.sleep(0.5)

log("드레인 시작")
conn.settimeout(5)
total = 0
fh = open(out_path, "wb")
last = time.time()
while True:
    try:
        buf = conn.recv(65536)
    except socket.timeout:
        log("5초간 더 온 것이 없다 — 종료")
        break
    if not buf:
        log("상대가 닫았다")
        break
    total += len(buf)
    fh.write(buf)
    if time.time() - last >= 1.0:
        log("누적 %d 바이트" % total)
        last = time.time()
fh.close()
log("총 %d 바이트, %s" % (total, out_path))
with open(out_path + ".count", "w") as f:
    f.write("%d\n" % total)
