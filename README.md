# scraper_lambda — 경기대 기숙사 식단 스크래퍼

경기대 기숙사 식단 페이지에서 **이번 주(일~토) 식단 7일치**를 긁어 CSV로 만들고 S3(`kiryong-menu-csv/output.csv`)에 올린다.
같은 코드를 **EC2 서버(cron)** 와 **AWS Lambda** 두 곳에서 돌릴 수 있다.

> 2026-10 기준 **실제로 쓰는 쪽은 EC2 cron**이다.
> Lambda는 학교 사이트가 404("서비스 이용에 불편을 드려… 업데이트 준비중")를 돌려줘서 0건이 나온다.
> URL·헤더는 같은데 Lambda(AWS IP)에서만 막히므로 IP 차단으로 추정한다. 아래 [트러블슈팅](#트러블슈팅-기록) 참고.

---

## 한눈에 보기

```
[EC2 cron]
  평일 10:00~18:50, 10분마다 ──▶ main.py ──▶ 식단 크롤링 ──▶ S3 output.csv 갱신
  매주 월 12:00 ──────────────▶ weekly_check.py ──▶ main 실행 ──▶ 디스코드 알림 (성공/실패)
```

---

## 서버 cron (EC2 `ubuntu@ip-172-31-47-226`)

`crontab -l` 결과 (서버 시간대가 **Asia/Seoul** 이라는 전제의 시간들):

```cron
0 3 * * * /usr/local/bin/renew-certs.sh
*/10 10-18 * * 1-5 cd /home/ubuntu/scraper_lambda && flock -n /tmp/scraper.lock .venv/bin/python main.py >> cron.log 2>&1
0 12 * * 1 cd /home/ubuntu/scraper_lambda && flock -w 300 /tmp/scraper.lock .venv/bin/python weekly_check.py >> weekly.log 2>&1
```

| 줄 | 언제 | 무엇을 | 로그 |
|---|---|---|---|
| 1 | 매일 03:00 | 인증서 갱신 (**이 프로젝트와 무관**, 원래 있던 작업) | - |
| 2 | 월~금 10:00, 10:10 … 18:50 (하루 54번) | `main.py` — 크롤링 후 S3 업로드 | `cron.log` |
| 3 | 매주 월요일 12:00 | `weekly_check.py` — main 실행 후 디스코드로 결과 알림 | `weekly.log` |

### cron 문법 메모
```
분  시   일  월  요일
*/10 10-18 *  *  1-5     → 10~18시대, 10분마다, 월(1)~금(5)
0    12    *  *  1       → 월요일 12:00 정각
```
- 서버 시간대 확인: `timedatectl | grep "Time zone"`. **UTC로 바뀌면 시간을 9시간 빼야 한다** (KST 12:00 = UTC 03:00).
- 정각 0~1초 안에 시작하고, 크롤링+업로드까지 몇 초 더 걸린다. 서버가 꺼져 있던 시간의 실행은 **건너뛴다**(나중에 대신 안 돌림).

### `flock`을 쓰는 이유
월요일 12:00엔 2번 줄과 3번 줄이 **동시에** 돌아 같은 `output.csv`를 쓰게 된다. `/tmp/scraper.lock` 으로 한 번에 하나만 돌게 했다.
- `flock -n` (10분 작업): 다른 작업이 돌고 있으면 **이번 회차는 건너뜀**
- `flock -w 300` (주간 점검): 최대 **5분 기다렸다가** 실행

### cron 수정할 때 주의
- `crontab -e` 로 직접 고치는 게 가장 안전하다.
- `(crontab -l | grep -v 'scraper_lambda'; echo ...) | crontab -` 형태 명령은 **scraper_lambda가 들어간 줄을 전부 지운다** (2·3번 줄 둘 다). 쓸 거면 두 줄을 같이 다시 넣을 것.

### 자주 쓰는 확인 명령 (서버)
```bash
crontab -l                                        # 등록된 cron 보기
tail -n 30 ~/scraper_lambda/cron.log              # 10분 작업 최근 로그
tail -n 30 ~/scraper_lambda/weekly.log            # 주간 점검 최근 로그
grep CRON /var/log/syslog | tail -n 10            # cron이 실제로 언제 돌았는지
cd ~/scraper_lambda && .venv/bin/python main.py           # 수동 실행 (마지막 줄 {'ok': True, ...} 면 정상)
cd ~/scraper_lambda && .venv/bin/python weekly_check.py   # 디스코드 알림까지 수동 테스트
```
`cron.log` 는 계속 쌓이므로 가끔 비우거나, cron 줄의 `>>` 를 `>` 로 바꾸면 마지막 실행 로그만 남는다.

---

## 파일 구성

| 파일 | 역할 |
|---|---|
| `main.py` | 진입점. 스파이더 실행 → CSV 검사 → S3 업로드. `lambda_handler(event, context)` 가 Lambda 핸들러이자 `python main.py` 로 직접 실행할 때도 쓰인다 |
| `dorm_spider.py` | Scrapy 스파이더. 오늘(KST) 날짜로 식단 페이지를 요청하고 표에서 날짜/아침/점심/저녁을 뽑는다 |
| `weekly_check.py` | 주간 점검. `main.lambda_handler` 를 돌려 `ok` 면 성공, 예외/`ok` 아님이면 실패 메시지를 디스코드로 보낸다 |
| `requirements.txt` | `boto3`, `scrapy`, `python-dotenv` (버전 고정 안 됨 — 아래 주의 참고) |
| `Dockerfile` | Lambda 컨테이너 이미지 (`amazon/aws-lambda-python:3.11`) |
| `deploy.ps1` | Lambda 배포 스크립트 (Windows PowerShell). **`.gitignore`의 `*.ps1` 때문에 git에 안 올라감** |
| `.env` | 설정값 (git 제외) |

### main.py 흐름
1. `.env` 로드 → `S3_BUCKET`, `S3_PREFIX`, `CSV_NAME` 등 읽음
2. `run_spider_to_csv()` — **자식 프로세스**(`multiprocessing.Process`)에서 Scrapy 실행
   - Twisted reactor는 프로세스당 한 번만 시작 가능 → Lambda 웜 컨테이너 재호출 시 `ReactorNotRestartable` 이 났기 때문
3. CSV가 헤더뿐이면(0건) `Exception("No data scraped (all empty)")` → **업로드 안 함**
4. `s3.upload_file()` 로 `S3_BUCKET/CSV_NAME` 에 업로드 → `{"ok": True, "bucket": ..., "key": ...}` 반환

기타 설정: 텔넷 콘솔·원격제어 HTTP 서버 끔, boto DEBUG 로그 숨김(서명·Access Key ID가 찍힘), `EncodingFixerMiddleware` 로 euc-kr 페이지를 cp949로 디코딩.

### dorm_spider.py 요청 URL
```
https://dorm.kyonggi.ac.kr:446/Khostel/mall_main.php?viewform=B0001_foodboard_list&gyear=2026&gmonth=10&gday=30
```
- 넣은 날짜가 포함된 **주(일~토)** 가 나온다. `gday=03` / `gday=3` 둘 다 됨.
- `...&board_no=1` URL도 같은 이번 주 페이지가 나온다(날짜 지정 불가).
- 날짜는 **KST 기준** (Lambda가 UTC라 00~09시에 전날로 요청하던 문제 수정).
- 일주일 전부 "미운영"이면 아무것도 저장 안 함 → main에서 0건 예외.
- 200이 아닌 응답(404 등)은 상태코드·헤더·화면 텍스트를 `ERROR` 로그로 남긴다 (원인 파악용).
- Scrapy 2.13+ 의 `async def start()` 와 예전 `start_requests()` 둘 다 정의 — **Scrapy 2.19는 `start_requests()` 를 안 불러서 요청이 0건이던 문제** 수정.

### weekly_check.py 알림
- 성공: `✅ Scraper 주간 점검 성공` → `SUCCESS_WEBHOOK_URL` 이 있으면 거기로, 없으면 `DISCORD_WEBHOOK_URL`
- 실패: `⚠️ Scraper 주간 점검 실패 ⚠️` + Error + Traceback(끝 1500자, 디스코드 2000자 제한) → `DISCORD_WEBHOOK_URL`
- `DISCORD_WEBHOOK_URL` 이 비어 있으면 성공 알림도 안 보낸다(함수 첫 줄에서 바로 리턴).

---

## 환경변수 (`.env`)

| 키 | 예시/설명 |
|---|---|
| `S3_BUCKET` | `kiryong-menu-csv` (필수) |
| `S3_PREFIX` | CSV 로컬 저장 위치 앞부분. Lambda는 `/tmp/` (쓰기 가능한 유일한 곳), 서버는 비워두면 현재 폴더 |
| `CSV_NAME` | `output.csv` — 로컬 파일명이자 S3 키 |
| `CSV_UTF8_SIG` | `1` 이면 UTF-8 BOM (엑셀에서 한글 안 깨짐). 문자열이라 `0`도 참으로 처리되니 끄려면 줄을 지울 것 |
| `SCRAPY_LOG_LVL` | `INFO` 권장 (`DEBUG` 면 로그가 매우 길어짐) |
| `DISCORD_WEBHOOK_URL` | 실패 알림(기본) 웹훅 |
| `SUCCESS_WEBHOOK_URL` | 성공 알림 전용 웹훅 (선택) |

Lambda에서는 함수 환경변수가 `.env` 보다 우선한다(`load_dotenv` 는 기존 값을 덮어쓰지 않음).

---

## 서버(EC2) 처음 설치하는 법

Ubuntu 24.04는 시스템 pip 설치를 막으므로(`externally-managed-environment`) 가상환경을 쓴다.
```bash
sudo apt update && sudo apt install -y python3-venv
cd ~/scraper_lambda && python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python main.py
```
S3 업로드 권한이 필요하다 (EC2 IAM 역할 또는 `aws configure`).

---

## Lambda 배포 (`deploy.ps1`, Windows)

```powershell
cd C:\code\scraper_lambda
powershell -NoProfile -ExecutionPolicy Bypass -File deploy.ps1
```
- 하는 일: Docker 빌드 → ECR `381305464439.dkr.ecr.ap-northeast-2.amazonaws.com/dorm-scraper:latest` 푸시 → Lambda `kiryong-scraper` 이미지 교체 → 메모리 1024MB / 타임아웃 120초 / 환경변수 적용
- **Docker Desktop이 켜져 있어야 함.**
- 환경변수는 기존 Lambda 값에 **병합**된다(스크립트 값 우선). `MODE=prod` 처럼 함수에만 있는 값은 유지.
- IAM 사용자 `BE` 는 `iam:GetRole`, `lambda:InvokeFunction`, CloudWatch Logs 읽기 권한이 없다 → 역할 확인 단계 에러는 무시해도 되고, 호출/로그 확인은 콘솔이나 권한 있는 계정으로.
- `*>&1` 로 출력을 리다이렉트해서 실행하면 Docker 진행 메시지가 에러로 처리돼 중간에 멈춘다. 위처럼 별도 프로세스로 실행할 것.
- `Dockerfile` 이 폴더 전체(`.env` 포함)를 이미지에 넣으므로 **웹훅 URL도 ECR 이미지 안에 들어간다.**

---

## 트러블슈팅 기록

| 증상 | 원인 | 조치 |
|---|---|---|
| Lambda `ReactorNotRestartable` (가끔) | 웜 컨테이너에서 Twisted reactor 재시작 불가 | 크롤링을 자식 프로세스에서 실행 (`main.run_spider_to_csv`) |
| `deploy.ps1` ECR 로그인 400 Bad Request | PowerShell 5.1 파이프가 토큰을 깨뜨림 | `cmd /c "aws ecr get-login-password ... \| docker login ..."` 로 변경 |
| Docker 빌드 실패 `No matching distribution found for subprocess` | `requirements.txt` 에 표준 라이브러리 `subprocess` 가 들어 있었음 | 삭제 |
| Lambda 환경변수 적용 실패 `could not be decoded` | PS 5.1 `Set-Content -Encoding UTF8` 이 BOM을 붙임 | `Write-Utf8NoBom` 으로 BOM 없이 저장 |
| Lambda가 전날 날짜로 요청 | Lambda는 UTC | KST(UTC+9)로 날짜 계산 |
| Lambda만 404 "업데이트 준비중" | 학교 서버가 AWS IP를 거부하는 것으로 추정 (같은 URL/헤더가 국내 PC에선 200) | 크롤링을 서버 cron으로 이동. Lambda로 하려면 국내 프록시나 고정 IP 허용 요청 필요 |
| 서버에서 0건인데 성공 알림 + **빈 파일 S3 업로드** | Scrapy 2.19가 `start_requests()` 를 안 부름 + 서버에 0건 검사가 빠진 옛 `main.py` | `async def start()` 추가, 최신 `main.py` 로 교체 |

### 주의
- `requirements.txt` 가 버전을 고정하지 않아서 설치 시점마다 Scrapy 버전이 다르다 (로컬 2.13.3, 서버 2.19.0). 또 깨지면 `scrapy==<동작하던 버전>` 으로 고정할 것.
- 로컬에서 고친 파일은 **서버에 직접 복사**해야 반영된다 (`main.py`, `dorm_spider.py`, `weekly_check.py`).
<img width="1587" height="2245" alt="DB 저장 API 요청" src="https://github.com/user-attachments/assets/7d993aaf-8607-4a46-bac5-5580bd0f0402" />
