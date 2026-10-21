# XP 실기 A/B — LPT 블로킹 쓰기  2026-09-17

리눅스 하니스에서 규명한 것을 **실제 사용 환경(WinXP 게스트)** 에서 확인한 기록이다.
`FINDINGS.md` 의 리눅스 결과와 짝을 이룬다.

## 대상

| | |
|---|---|
| 전 | `qemu-system-i386.bak-20260917-prelpt` = `v11.1.0-1474-g43922bf55e` |
| 후 | `qemu-system-i386` = `v11.1.0-1475-g7a7af93fe3` (= 전 + LPT 논블로킹 커밋 하나) |

두 바이너리의 차이는 `hw/char/parallel` 커밋 **하나뿐**이다(UI 5건·PS/2 1건은 양쪽 다 포함).

구성: q35, 2GB, `-cpu host -accel kvm`, `-display none`, `-serial none`,
`-chardev socket,host=127.0.0.1,port=9110` + `-parallel chardev:lpt`.
디스크 두 개 모두 `snapshot=on` — 시험 후 `qemu-img check` 로 원본 무결성 확인(둘 다 No errors).

싱크(`scripts/stall-sink.py`)는 accept 후 **한 바이트도 읽지 않는다**
(`SO_RCVBUF` 로 4096 을 요청하지만 리눅스는 2배로 잡으므로 실효 8KB).
`.drain` 트리거를 주면 그때부터 빨아들이며 총 바이트를 센다.

게스트 부하는 프린터 드라이버 없이 cmd 에서 `copy /b <파일> lpt1:`.
키 주입·화면 캡처·응답성 감시는 `scripts/monctl.py`, 런처는 `scripts/lpt-xp.sh`.

## 1. 문턱 — 1MB 짜리 작업으로는 재현되지 않는다

`copy /b c:\windows\explorer.exe lpt1:` (1,031,680 바이트) 는 싱크가 전혀 읽지
않는데도 **정상 완료**했고, monitor 는 110초 내내 `rtt=0.150s` 로 응답했다.

커널이 다 먹어 준 것이다. 완료 시점 분포가 정확히 이랬다.

    QEMU 쪽 Send-Q   1,025,049
    싱크 쪽 Recv-Q       6,631
    합계             1,031,680 = explorer.exe 크기

`net.ipv4.tcp_wmem` 상한이 4MB 이므로 이 크기로는 `EAGAIN` 에 닿지 못한다.
문턱을 리눅스 하니스와 나란히 놓은 표와 그 함의는 `FINDINGS.md` 2단계
「제보와의 대조」에 있다.

## 2. 「전」 — 버퍼가 차면 QEMU 전체가 언다

같은 VM 에서 `copy /b c:\windows\system32\*.dll lpt1:` (수십 MB).
XP 의 LPT 출력 속도는 약 10KB/s.

| 시점 | 관측 |
|---|---|
| t=0~79s | monitor OK. Send-Q 1.03MB → 1.79MB |
| **t=80.5s** | **첫 무응답. Send-Q 1,792,000 에서 정지** |
| t=80.5~128s | 연속 무응답 **67회**(1초 간격) |

정체 중 스레드:

    CPU 0/KVM      wchan=hrtimer_nanosleep   ← qemu_chr_write_buffer() 의 g_usleep(100) 재시도
    메인 스레드     wchan=futex_do_wait       ← BQL 을 못 받는다
    프로세스        %CPU 32%

페이로드 1.79MB 에서 걸린 이유: `sk_wmem_queued` 는 skb 오버헤드까지 세므로
페이로드 기준으로는 4MB 상한보다 일찍 한계에 닿는다.

**SIGTERM 무시**: 02:34:22 에 보냈고 12초 뒤에도 생존, wchan 동일.

## 3. 「전」 — 싱크를 읽어 주면 그 자리에서 풀린다

드레인 트리거 → 싱크가 **1,798,632 바이트**를 받고 곧바로 "상대가 닫았다".
막혀 있던 write 가 완료되자 QEMU 가 **대기 중이던 SIGTERM 을 즉시 처리하고 종료**했다.

즉 SIGTERM 은 무시된 것이 아니라 **처리될 차례를 얻지 못하고 있었을 뿐**이다.
프리즈의 정체가 그 write 하나였다는 인과가 여기서 닫힌다.

(리눅스 하니스에서는 배수 후에도 회복하지 않은 런이 한 건 있었다. XP 에서는 1/1 로 회복.)

## 4. 「후」 — 같은 지점에서 막히지만 QEMU 는 멀쩡하다

부하: `copy /b explorer.exe+explorer.exe+explorer.exe+explorer.exe lpt1:`
= **4 × 1,031,680 = 4,126,720 바이트**.

| | 전 | 후 |
|---|---|---|
| Send-Q 정지 지점 | **1,792,000** | **1,792,000** (동일) |
| monitor `info status` | 무응답 67회 | **무응답 0회** (t=343s 까지 전 구간 OK) |
| `info chardev` | 무응답 | 정상 응답 |
| vCPU 스레드 | `hrtimer_nanosleep` | `kvm_vcpu_block` |
| 메인 스레드 | `futex_do_wait` | `poll_schedule_timeout` (정상 메인 루프) |
| 게스트 | 같이 멈춤 | `copy` 만 대기 |
| SIGTERM | 12초 무반응 | **2초 내 종료** |

같은 바이트 수에서 똑같이 막히는데 한쪽은 QEMU 가 통째로 얼고,
다른 쪽은 **게스트만 기다린다**. 이것이 패치의 전부다.

## 5. 「후」 — 손실 0, 게스트는 완주한다

배압을 180초 유지한 뒤 드레인 트리거.

    수신 총량      4,126,720 바이트
    기대 총량      4,126,720 = 4 × 1,031,680
    차이           0
    4등분 블록     전부 바이트 단위 동일

게스트는 재개해 `copy` 를 끝까지 마쳤다("1개 파일이 복사되었습니다").
리눅스 하니스의 손실 0(1,638,400 = 200×8192)과 같은 결론이 두 번째 게스트에서 확증됐다.

## 6. XP 고유 관측

- **전송 타임아웃은 걸리지 않았다.** 배압을 180초 받는 동안 XP 는 에러 대화상자를
  띄우지 않았고 `copy` 는 조용히 기다렸다. 프린터 포트의 「전송 다시 시도」(기본
  90초대)는 스풀러 경로의 설정이고, raw `copy ... lpt1:` 은 그 층을 타지 않는 것으로
  보인다.
- 병렬 포트를 붙이자 XP 가 **새 하드웨어 검색 마법사**를 띄웠다. 기존 런처는
  `-parallel none` 이라 없던 장치다.
- 화면이 640x480 으로 떴다(기존 1024x768 하니스와 다름). 이번 목적에는 무관.

## 7. 드라이버·스풀러 경로 인쇄 — 실사용 형태로 확인

위 4~6번은 `copy /b ... lpt1:` 로 포트에 직접 쓴 것이다. 실제 사용 형태(프린터
드라이버 → 스풀러 → LPT1)도 따로 돌렸다.

구성은 계측용 하니스가 아니라 **평소 쓰는 런처** 그대로다 — `winxp.sh` 를
`PRINTER=1` 로 켜서 회피책 경로(파일 싱크)를 그대로 태웠다.

    -chardev file,id=cups_printer,path=$WORK_DIR/printer/xp-<타임스탬프>.prn
    -parallel chardev:cups_printer
    -serial none

XP 에 설치된 `HP LaserJet 4V/4MV PostScript`(PScript5.dll 5.2.2) 드라이버로
Windows 프린터 테스트 페이지를 인쇄했다.

| | |
|---|---|
| 받은 바이트 | 146,613 |
| 형식 | PJL 로 감싼 PostScript (`@PJL SET RESOLUTION = 600` → `ENTER LANGUAGE = POSTSCRIPT`) |
| 작업 제목 | `테스트 페이지` (CP949) |
| 종료 | `%%EOF` → `^D` → `@PJL EOJ` → UEL. **잘리지 않았다** |
| 렌더 | ghostscript 로 PDF/PNG 변환 성공, 1페이지 A4, 내용 정상 |

**게스트도 QEMU 도 멈추지 않았다.** 인쇄 후에도 `VM status: running`.

포장을 벗겨 PDF 로 바꾸는 일은 반복되므로 `~/.local/bin/prn2pdf` 로 스크립트를
만들어 뒀다(앞 PJL 78바이트·뒤 30바이트를 떼고 본문만 ghostscript 에 넘긴다).

다만 이 런은 파일 싱크라 `EAGAIN` 이 날 일이 없다. **막히는 싱크에 스풀러
경로로 인쇄했을 때** XP 가 몇 초 만에 무엇을 하는지(전송 다시 시도 타임아웃,
작업 재시작)는 여전히 미검증이다. 146KB 는 커널 버퍼에 들어가는 크기라
예전 소켓 설정이었어도 이 작업만으로는 얼지 않았을 것이다.

## 8. 남은 것

미결 목록은 `FINDINGS.md` 의 「남은 것」 한 곳에 모아 두었다. XP 에서 나온 두 건
— 배압 조건의 스풀러 경로(7절), 드레인 후 회복이 갈리는 조건(3절) — 도 거기에 있다.
