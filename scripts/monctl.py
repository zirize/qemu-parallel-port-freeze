#!/usr/bin/env python3
"""QEMU HMP monitor(UNIX 소켓) 조종 도구.

  monctl.py <sock> cmd  "<HMP 명령>"      한 줄 보내고 응답을 찍는다
  monctl.py <sock> type "<문자열>"        sendkey 로 한 글자씩 타이핑
  monctl.py <sock> shot <파일.ppm>        screendump + 해상도 출력
  monctl.py <sock> watch <초> [로그파일]  1초마다 info status 왕복, 응답성 기록

watch 가 핵심이다. 블로킹 쓰기에 걸린 QEMU 는 BQL 을 놓지 않으므로
monitor 가 명령에 응답하지 못한다 — 게스트가 혼자 바쁜 대기를 도는 경우와
여기서 갈린다.
"""
import socket
import sys
import time

sock_path = sys.argv[1]
verb = sys.argv[2]


def connect(timeout=3.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    return s


def talk(cmd, timeout=3.0):
    """명령 하나를 보내고 응답을 모은다. 응답이 없으면 socket.timeout."""
    s = connect(timeout)
    try:
        time.sleep(0.15)          # 배너
        try:
            s.recv(65536)
        except socket.timeout:
            pass
        s.sendall((cmd + "\n").encode())
        out = b""
        end = time.time() + timeout
        while time.time() < end:
            try:
                buf = s.recv(65536)
            except socket.timeout:
                break
            if not buf:
                break
            out += buf
            if b"(qemu)" in out[len(cmd):]:
                break
        return out.decode(errors="replace")
    finally:
        s.close()


KEYMAP = {
    " ": "spc", ":": "shift-semicolon", "\\": "backslash", ".": "dot",
    "/": "slash", "-": "minus", "_": "shift-minus", ",": "comma",
    ";": "semicolon", "=": "equal", "*": "shift-8", '"': "shift-apostrophe",
    "'": "apostrophe", ">": "shift-dot", "<": "shift-comma", "?": "shift-slash",
    "+": "shift-equal", "(": "shift-9", ")": "shift-0", "!": "shift-1",
    "&": "shift-7", "%": "shift-5", "#": "shift-3", "$": "shift-4",
    "@": "shift-2", "^": "shift-6", "~": "shift-grave_accent", "|": "shift-backslash",
}


def keyname(ch):
    if ch in KEYMAP:
        return KEYMAP[ch]
    if ch.isdigit() or (ch.isalpha() and ch.islower()):
        return ch
    if ch.isalpha() and ch.isupper():
        return "shift-" + ch.lower()
    raise SystemExit("매핑 없는 문자: %r" % ch)


if verb == "cmd":
    print(talk(sys.argv[3]))

elif verb == "type":
    text = sys.argv[3]
    s = connect(5.0)
    time.sleep(0.15)
    try:
        s.recv(65536)
    except socket.timeout:
        pass
    for ch in text:
        s.sendall(("sendkey %s\n" % keyname(ch)).encode())
        time.sleep(0.06)
        try:
            s.recv(65536)
        except socket.timeout:
            pass
    s.close()
    print("typed %d chars" % len(text))

elif verb == "shot":
    path = sys.argv[3]
    talk("screendump " + path)
    time.sleep(0.8)
    try:
        with open(path, "rb") as f:
            head = f.read(64).split()
        print("%s %sx%s" % (path, head[1].decode(), head[2].decode()))
    except Exception as e:
        print("screendump 실패: %s" % e)

elif verb == "watch":
    secs = int(sys.argv[3])
    log = open(sys.argv[4], "w") if len(sys.argv) > 4 else sys.stdout
    t0 = time.time()
    ok = dead = 0
    while time.time() - t0 < secs:
        t = time.time() - t0
        start = time.time()
        try:
            out = talk("info status", timeout=2.0)
            rtt = time.time() - start
            state = "?"
            for line in out.splitlines():
                if "VM status" in line:
                    state = line.strip()
            print("[%6.1f] OK  rtt=%.3fs  %s" % (t, rtt, state), file=log, flush=True)
            ok += 1
        except Exception as e:
            print("[%6.1f] NO-RESPONSE  %s" % (t, type(e).__name__), file=log, flush=True)
            dead += 1
        time.sleep(1.0)
    print("---- 응답 %d회 / 무응답 %d회 ----" % (ok, dead), file=log, flush=True)

else:
    raise SystemExit("알 수 없는 동작: %s" % verb)
