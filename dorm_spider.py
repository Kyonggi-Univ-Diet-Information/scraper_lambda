# dorm_spider.py
import scrapy
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))

class DormSpider(scrapy.Spider):
    name = "dorm"
    allowed_domains = ["dorm.kyonggi.ac.kr"]
    # Lambda에서만 404가 남 → 원인 확인용으로 404도 parse로 받아서 본문을 로그에 남김
    handle_httpstatus_list = [404]

    # Scrapy 2.13+는 start()를 호출하고, 최신 버전은 start_requests()를 더 이상 부르지 않음 → 요청 0건
    async def start(self):
        for request in self.start_requests():
            yield request

    def start_requests(self):
        # Lambda는 UTC라 KST 00~09시엔 전날 날짜가 됨 → KST 기준으로 고정
        today = datetime.now(KST)
        year  = today.strftime("%Y")
        month = today.strftime("%m")
        day   = today.strftime("%d")

        # year  = 2025
        # month = 10
        # day   = 7
        url = (
            "https://dorm.kyonggi.ac.kr:446/"
            f"Khostel/mall_main.php?viewform=B0001_foodboard_list&gyear={year}&gmonth={month}&gday={day}"
        )
        yield scrapy.Request(url=url, callback=self.parse)

    def parse(self, response):
        if response.status != 200:
            headers = {k.decode(): v[0].decode("latin-1") for k, v in response.headers.items()}
            self.logger.error("Non-200 response %s from %s", response.status, response.url)
            self.logger.error("Response headers: %s", headers)
            # 앞부분이 전부 CSS라 화면에 보이는 텍스트만 추출
            texts = response.xpath(
                "//body//text()[not(ancestor::style) and not(ancestor::script)]"
            ).getall()
            visible = " | ".join(t.strip() for t in texts if t.strip())
            self.logger.error("Response size: %d bytes", len(response.body))
            self.logger.error("Response text: %s", visible[:2000])
            return

        items = []

        for row in response.css("table.boxstyle02 tbody tr"):
            date_text = row.css("th a::text").get() or row.css("th::text").get(default="")
            date_text = date_text.strip()

            tds = row.css("td")

            def join_text(sel):
                texts = [t.strip() for t in sel.css("::text").getall() if t.strip()]
                return "&".join(texts) if texts else "미운영"

            breakfast = join_text(tds[0]) if len(tds) > 0 else "미운영"
            lunch     = join_text(tds[1]) if len(tds) > 1 else "미운영"
            dinner    = join_text(tds[2]) if len(tds) > 2 else "미운영"

            items.append({
                "date": date_text,
                "breakfast": breakfast,
                "lunch": lunch,
                "dinner": dinner,
            })

        # ---- 여기서 일주일치 전부 비었는지 체크 ----
        if all(
            i["breakfast"] == "미운영" and
            i["lunch"] == "미운영" and
            i["dinner"] == "미운영"
            for i in items
        ):
            # None 리턴 → Scrapy에서는 아무 것도 저장되지 않음
            return None

        # 하나라도 운영 중이면 그대로 yield
        for item in items:
            yield item

