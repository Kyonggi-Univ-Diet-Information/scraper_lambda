"""
매주 월요일 cron으로 실행: 스크래퍼를 돌려보고 결과를 디스코드로 알림.
웹훅 URL은 .env 또는 환경변수 DISCORD_WEBHOOK_URL 에서 읽음.
"""
import os
import sys
import json
import datetime
import traceback
import urllib.request
import urllib.error

import main  # import 시 .env 로드됨

DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
SUCCESS_WEBHOOK_URL = os.environ.get("SUCCESS_WEBHOOK_URL", "")

def send_discord(content: str) -> dict:
    if not DISCORD_WEBHOOK_URL:
        print("DISCORD_WEBHOOK_URL is missing.")
        return {"status": "failed", "error": "Webhook URL is missing."}

    data = json.dumps({"content": content}).encode("utf-8")
    req = urllib.request.Request(
        SUCCESS_WEBHOOK_URL if content.startswith("✅") and SUCCESS_WEBHOOK_URL else DISCORD_WEBHOOK_URL,
        data=data,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "curl/7.79.1"   # Discord가 잘 받는 UA
        }
    )

    try:
        with urllib.request.urlopen(req) as resp:
            return {"status": "sent", "http_status": resp.getcode()}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print("Webhook HTTPError:", e.code, body)
        return {"status": "failed", "http_status": e.code, "body": body}
    except Exception as e:
        print("Webhook Exception:", str(e))
        return {"status": "failed", "error": str(e)}


def run() -> int:
    try:
        result = main.lambda_handler({}, None)
        if not result.get("ok"):
            raise Exception(result.get("error", "lambda_handler returned ok=False"))
    except Exception as e:
        if "No data scraped" in str(e):
            print("메뉴 미게시: 다음 회차에 재시도")
            now = datetime.datetime.now()
            if now.weekday() == 4 and now.hour >= 13:  # 금요일 마지막 시도
                print(send_discord("⚠️ 금요일까지 이번 주 메뉴를 찾지 못함 (미게시 또는 사이트 변경)"))
            return 1

        cause = traceback.format_exc()[-1500:]  # 디스코드 메시지 2000자 제한
        print(send_discord(
            "⚠️ Scraper 주간 점검 실패 ⚠️\n\n"
            f"**Error**: {type(e).__name__}: {e}\n"
            f"**Cause**: ```\n{cause}\n```"
        ))
        return 1

    print(send_discord("✅ Scraper 주간 점검 성공"))
    return 0


if __name__ == "__main__":
    sys.exit(run())
