# qemu-parallel-port-freeze

📄 Project page: **[QEMU freezes when printing to a parallel port: the blocking chardev write](https://zirize.github.io/qemu-parallel-port-freeze/)** · More projects: **[zirize.github.io](https://zirize.github.io/)**

All three QEMU retro series (integer scaling, non-blocking LPT, CUE/BIN audio CDs) in one build: **[Building QEMU for retro guests](https://zirize.github.io/qemu-retro-patches/)**

**A parallel-port write can freeze the entire QEMU VM.** Not just the guest —
the monitor stops answering and the process ignores `SIGTERM`.

`hw/char/parallel.c` hands each strobed byte to the chardev backend with
`qemu_chr_fe_write_all()`, which retries `EAGAIN` in a `g_usleep(100)` loop.
The caller is a vCPU thread holding the BQL, so when the backend stops
draining — a socket chardev whose peer is connected but not reading — the
whole VM stops with it.

The code says so itself. Since 2016 (`6ab3fc32ea`):

```c
/* XXX this blocks entire thread. Rewrite to use
 * qemu_chr_fe_write and background I/O callbacks */
qemu_chr_fe_write_all(&s->chr, &s->dataw, 1);
```

That commit moved *away* from the non-blocking call, because the old code
ignored the return value and silently dropped bytes. Data loss was traded for
a blocked thread. This repository documents what that costs in practice,
and contains a patch that pays neither price: it asserts the printer's BUSY
line while the backend is full, so the guest waits the way it would for a slow
printer, and the vCPU thread stays free.

## Symptoms

If this is what you are hitting, you will have seen some of these:

- The guest hangs while printing to a parallel port (`LPT1`), usually part-way
  through a job, and never comes back.
- QEMU itself stops responding. The HMP monitor accepts a connection but never
  answers `info status`; the display stops redrawing.
- `SIGTERM` appears to be ignored and only `kill -9` ends the process. It is not
  really ignored — the signal is waiting its turn behind the stuck write, and
  QEMU exits the moment the write completes.
- It happens with a `socket` chardev whose peer is connected but has stopped
  reading — a print spooler that stalled, for instance. A `file` chardev never
  triggers it, because writing to a file does not return `EAGAIN`.
- Small jobs do not trigger it. The kernel socket buffer swallows them whole, so
  a one-megabyte job can finish while nothing on the far end reads a single byte.

| | before | after |
|---|---|---|
| HMP `info status` while stalled | no answer | `VM status: running` |
| vCPU thread | `hrtimer_nanosleep` (spinning) | `kvm_vcpu_block` (idle) |
| `SIGTERM` | ignored, needs `kill -9` | exits in 2s |
| bytes delivered after the peer resumes reading | not guaranteed | all of them, byte-exact |

Verified on two guests — a 0.2-second-boot Linux harness and a real Windows XP
install — against QEMU 11.1.50 (`v11.1.0-1474-g43922bf55e`).

**[Read the write-up →](https://zirize.github.io/qemu-parallel-port-freeze/)** (English)

**The detailed documents in this repository are in Korean.** 아래 문서는 한국어입니다.

---

## 문서

| | |
|---|---|
| [`FINDINGS.md`](FINDINGS.md) | 계측 → 원인 규명 → 근본 수정 → 검증 (최소 리눅스 하니스) |
| [`FINDINGS-XP.md`](FINDINGS-XP.md) | WinXP 실기 A/B 교차 검증 |
| [`patches/`](patches/) | QEMU 논블로킹 패치 |
| [`evidence/`](evidence/) | 정체 시점 스택, 트레이스 요약 |

## 무엇이 문제인가

병렬 포트에 strobe 가 걸릴 때마다 QEMU 는 바이트 하나를 chardev 로 내보낸다.
그 호출이 `qemu_chr_fe_write_all()` 이고, `chardev/char.c` 에서 이렇게 돈다.

```c
retry:
    res = cc->chr_write(s, buf + *offset, len - *offset);
    if (res < 0 && errno == EAGAIN && write_all) {
        g_usleep(100);
        goto retry;          /* 무한 재시도 */
    }
```

이걸 **BQL 을 쥔 vCPU 스레드**가 돈다. 정체 시점의 스택이 그대로 보여준다.

```
TID (vCPU)                         TID (메인 스레드)
  g_usleep                           __lll_lock_wait
  qemu_chr_write_buffer              __pthread_mutex_lock
  qemu_chr_write                     qemu_mutex_lock_impl
  parallel_ioport_write_sw           main_loop_wait
  memory_region_write_accessor
```

왼쪽이 오른쪽을 굶긴다. 게스트가 멈추는 것은 물론이고 모니터도, 시그널 처리도
같이 죽는다. `SIGTERM` 이 무시되는 것이 아니라 **처리될 차례를 얻지 못한다** —
막힌 write 가 풀리는 순간 대기 중이던 SIGTERM 을 그 자리에서 처리하고 종료한다.

## 어떻게 고쳤나

실제 프린터는 데이터를 못 받을 때 BUSY 를 세운다. 병렬 포트의 호스트 쪽에는
버스를 스톨시킬 방법이 애초에 없다. 그러니 백엔드가 막히면 같은 일을 하면 된다.

- `qemu_chr_fe_write()` 로 바꾸고 `EAGAIN` 이면 `G_IO_OUT` watch 를 걸고 즉시 반환
- 그동안 **BUSY 를 어서트한 채 유지** — 게스트는 느린 프린터를 기다리듯 기다린다
- 상태 레지스터의 ACK/BUSY 복원 시퀀스도 전송 중에는 막는다
  (안 그러면 게스트가 꽉 찬 파이프에 다음 바이트를 밀어넣는다)
- ACK IRQ 는 바이트가 실제로 나간 뒤로 보류
- pending 바이트는 마이그레이션 상태다 — vmstate 서브섹션 + `post_load` 재무장

`file` chardev 는 `EAGAIN` 을 내지 않으니 무영향이고, 미연결 소켓은 `EIO` 로
기존과 같이 바이트를 버린다.

## 함정 — 작은 작업으로는 재현되지 않는다

커널 송신 버퍼가 먼저 다 받아 주기 때문에, 작업이 그보다 작으면 상대가 한 바이트도
안 읽어도 아무 일이 없다.

| | 막힌 지점 |
|---|---|
| 리눅스 하니스 | 1,357,824 바이트 |
| WinXP 실기 | 1,792,000 바이트 |
| 참고 — XP 프린터 테스트 페이지 1장 | 146,613 바이트 (문턱의 12분의 1) |

XP 에서 1MB 짜리 작업(`copy /b explorer.exe lpt1:`)은 싱크가 전혀 읽지 않아도
**정상 완료**한다. **작은 작업으로 시험하고 「재현 안 됨」이라 결론 내리면 안 된다.**

## 재현

### 최소 리눅스 게스트 (권장)

부팅부터 결과 출력까지 0.2초, 유휴 상태에서 LPT 접근 0건. 커널 8MB + 정적
busybox 1MB 로 만든다. 데스크톱 ISO 를 안 쓰는 이유는 크기가 아니라 **노이즈**다 —
X·udev·데몬이 도는 게스트로는 어떤 접근이 누구 것인지 귀속이 안 된다.

```bash
guest/fetch-deps.sh          # 커널·busybox·parport 모듈 (최초 1회, 약 180MB)
guest/build-initramfs.sh     # initramfs 생성

export LPT_BIN=<시험할 qemu-system-i386 경로>
scripts/lpt-linux.sh spin spin      # IEEE-1284 협상 스핀
scripts/lpt-linux.sh print print    # SPP strobe 로 실제 출력

# 프리즈 재현 — 상대가 안 읽는 싱크를 먼저 띄운다
scripts/stall-sink.py 600 /tmp/sink.bin &
NOTRACE=1 FLOODN=1024 \
  LPT_CHARDEV="socket,id=lptfile,host=127.0.0.1,port=9100,server=off" \
  TMO=240 scripts/lpt-linux.sh freeze flood
```

프로브: `detect` `negotiate` `spin` `print` `one` `idle` `driver` `flood` `irq` `shell`.

**갇혔는지는 모니터로 가른다.** 블로킹 쓰기는 BQL 을 쥐므로 모니터까지 죽지만,
게스트 혼자 도는 바쁜 대기는 모니터에 영향이 없다.

```bash
echo info status | socat -T5 - UNIX-CONNECT:logs/<태그>-mon.sock
```

### Windows 게스트

`scripts/lpt-xp.sh` 는 모니터 소켓으로 키를 주입해 `copy /b <파일> lpt1:` 을
실행시키고 응답성을 감시한다. `WORK_DIR` 에 이미지 디렉토리를 지정할 것.
**항상 `snapshot=on`** 으로 띄운다 — 프리즈 시험은 강제 종료가 반복된다.

## 패치 적용

```bash
cd <qemu-src>
git apply /path/to/patches/0001-parallel-nonblocking-tx.patch
```

QEMU 11.1.50(`v11.1.0-1474-g43922bf55e`) 기준으로 작성했다.

## 업스트림에 제출하지 않은 이유

QEMU 프로젝트는 **AI 가 생성했거나 그로부터 파생된 기여를 거절**한다
(`docs/devel/code-provenance.rst`, "Use of AI-generated content"). 근거는 DCO 이고
예외 목록은 비어 있다. 이 저장소의 조사와 패치는 Claude(Anthropic)를 써서 만들었으므로
패치 제출 경로가 닫혀 있다. 같은 절이 디버깅 용도는 정책 밖으로 두므로 패치 없는
버그 리포트는 가능했으나, 보내지 않기로 했다.

**그러니 이 패치는 업스트림에 반영되어 있지 않다.** 쓰려면 직접 적용해야 하고,
검증 결과는 위 문서에 있는 것이 전부다.

## 라이선스

GPL-2.0 ([`LICENSE`](LICENSE)).

`patches/` 안의 패치는 QEMU 의 `hw/char/parallel.c` 를 고친 것이다. 그 파일 자체는
MIT 계열 헤더를 달고 있으므로, 패치를 QEMU 에 적용해 쓸 때는 그 파일의 조건을
따른다. 이 저장소의 문서·하니스·스크립트가 GPL-2.0 이다.

## 문서에 나오는 로컬 참조

`winxp.sh`, `prn2pdf` 는 작성자의 로컬 런처·헬퍼이고 이 저장소에 없다.
`qemu_scaler_work` 는 같은 작성자의 다른 조사(별건)다. 맥락을 지우지 않으려고
그대로 두었다.
