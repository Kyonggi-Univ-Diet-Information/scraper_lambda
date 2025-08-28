# dorm_spider.py
import scrapy
from datetime import datetime

class DormSpider(scrapy.Spider):
    name = "dorm"
    allowed_domains = ["dorm.kyonggi.ac.kr"]

    def start_requests(self):
        today = datetime.now()
        year  = today.strftime("%Y")
        month = today.strftime("%m")
        day   = today.strftime("%d")

        url = (
            "https://dorm.kyonggi.ac.kr:446/"
            f"Khostel/mall_main.php?viewform=B0001_foodboard_list&gyear={year}&gmonth={month}&gday={day}"
        )
        yield scrapy.Request(url=url, callback=self.parse)

    def parse(self, response):
        # 원본이 euc-kr 이므로 디코딩
        # decoded = response.body.decode("euc-kr", errors="ignore")
        # response = response.replace(body=decoded.encode("utf-8"))

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

            yield {
                "date": date_text,
                "breakfast": breakfast,
                "lunch": lunch,
                "dinner": dinner,
            }
