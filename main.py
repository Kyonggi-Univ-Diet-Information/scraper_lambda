import os
import datetime
import logging
import multiprocessing
import boto3

from scrapy.crawler import CrawlerProcess
from scrapy.settings import Settings
from dorm_spider import DormSpider

import dotenv

dotenv.load_dotenv()

# Lambda 환경변수로부터 직접 가져오기
# S3_BUCKET      = os.environ.get("S3_BUCKET")                 # 필수
# S3_PREFIX      = os.environ.get("S3_PREFIX")           # 선택
# CSV_NAME       = os.environ.get("CSV_NAME")    # 선택
# CSV_UTF8_SIG   = os.environ.get("CSV_UTF8_SIG")  # 기본 True
# SCRAPY_LOG_LVL = os.environ.get("SCRAPY_LOG_LVL")

S3_BUCKET      = os.environ.get("S3_BUCKET")                 # 필수
S3_PREFIX      = os.environ.get("S3_PREFIX") or ""     # 선택 (없으면 "Noneoutput.csv"가 되는 것 방지)
CSV_NAME       = os.environ.get("CSV_NAME")    # 선택
CSV_UTF8_SIG   = os.environ.get("CSV_UTF8_SIG")  # 기본 True
SCRAPY_LOG_LVL = os.environ.get("SCRAPY_LOG_LVL")

s3 = boto3.client("s3")

# boto DEBUG 로그는 서명·Access Key ID까지 찍혀서 길고 민감함 → WARNING 이상만
for _name in ("boto3", "botocore", "s3transfer", "urllib3"):
    logging.getLogger(_name).setLevel(logging.WARNING)


class EncodingFixerMiddleware:
    """
    응답의 실제 인코딩을 점검해서 cp949/euc-kr 등을 강제로 지정.
    헤더/메타 태그에 힌트가 있으면 그걸 우선 사용.
    """
    CANDIDATES = ("euc-kr", "ks_c_5601", "cp949")

    def process_response(self, request, response, spider):
        try:
            ct = response.headers.get(b"Content-Type", b"").decode("ascii", "ignore").lower()
        except Exception:
            ct = ""
        body_lower = response.body[:4096].lower()  # 성능 때문에 앞쪽만 검사

        force = None
        if any(c in ct for c in self.CANDIDATES):
            force = "cp949"
        elif b"charset=euc-kr" in body_lower or b"charset=ks_c_5601" in body_lower:
            force = "cp949"

        # 필요시 강제 인코딩 적용
        if force:
            return response.replace(encoding=force)
        return response


def build_scrapy_settings(csv_path: str) -> Settings:
    s = Settings()
    s.set("DOWNLOADER_MIDDLEWARES", {
        "main.EncodingFixerMiddleware": 543,
    })
    s.set("ROBOTSTXT_OBEY", False)
    # 디버그용 원격 접속 기능 끔 (telnet 비밀번호 로그 노출, 최신 Scrapy는 HTTP 원격제어 포트까지 엶)
    s.set("TELNETCONSOLE_ENABLED", False)
    s.set("EXTENSIONS", {"scrapy.extensions.remote_control.RemoteControl": None})
    s.set("DOWNLOAD_TIMEOUT", 30)
    s.set("CONCURRENT_REQUESTS", 8)
    s.set("DEFAULT_REQUEST_HEADERS", {
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/120.0.0.0 Safari/537.36"
    })
    s.set("FEEDS", {
        csv_path: {
            "format": "csv",
            "overwrite": True,
            "encoding": "utf-8-sig" if CSV_UTF8_SIG else "utf-8",
            "fields": ["date", "breakfast", "lunch", "dinner"],
        }
    })
    return s


def _crawl(csv_path: str):
    logging.basicConfig(
        level=getattr(logging, SCRAPY_LOG_LVL.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(message)s"
    )
    process = CrawlerProcess(build_scrapy_settings(csv_path))
    process.crawl(DormSpider)
    process.start()


def run_spider_to_csv(csv_path: str):
    # Twisted reactor는 프로세스당 한 번만 시작 가능 → 웜 컨테이너 재호출 시 ReactorNotRestartable.
    # 매 호출마다 자식 프로세스에서 크롤링해서 reactor를 새로 띄운다.
    # (Lambda엔 /dev/shm이 없어서 Pool/Queue는 못 쓰고 Process만 사용)
    p = multiprocessing.Process(target=_crawl, args=(csv_path,))
    p.start()
    p.join()
    if p.exitcode != 0:
        raise RuntimeError(f"Spider process failed (exitcode={p.exitcode})")


def build_s3_key() -> str:
    t = datetime.datetime.utcnow()
    base = os.path.splitext(CSV_NAME)[0]
    return f"{base}.csv"


def lambda_handler(event, context):
    if not S3_BUCKET:
        return {"ok": False, "error": "Missing S3_BUCKET env"}

    local_csv = f"{S3_PREFIX}{CSV_NAME}"
    run_spider_to_csv(local_csv)

    # 크롤링 결과 확인
    with open(local_csv, "r", encoding="utf-8") as f:
        lines = f.readlines()

    if len(lines) <= 1:
        # 헤더만 있고 데이터 없음
        raise Exception("No data scraped (all empty)")

    s3_key = build_s3_key()
    content_type = "text/csv; charset=utf-8"
    s3.upload_file(
        local_csv,
        S3_BUCKET,
        s3_key,
        ExtraArgs={"ContentType": content_type}
    )

    return {"ok": True, "bucket": S3_BUCKET, "key": s3_key}


if __name__ == "__main__":
    print(lambda_handler({}, None))
