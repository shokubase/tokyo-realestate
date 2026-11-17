"""국토교통성 不動産情報ライブラリ 실거래가(중고 맨션) → Supabase.

사이트 검색 화면의 공개 CSV 다운로드 버튼을 Playwright로 누른다 (API 키 불필요).
  - 不動産取引価格情報 : 거래 당사자 설문 기반
  - 成約価格情報       : REINS(지정유통기구) 성약 기반
둘 다 건물명·호수는 없고 地区(동네)·면적·건축연도·분기 수준으로만 공개된다.

사용:
  poetry run python mlit.py --inspect            # 컬럼만 확인
  poetry run python mlit.py                      # 港区(13103) 최근 3년 적재
  poetry run python mlit.py --city 13103 --city 13113 --from 20221
"""

from __future__ import annotations

import argparse
import base64
import csv
import io
import json
import re
import sys
import unicodedata
import zipfile
from datetime import date

from playwright.sync_api import sync_playwright

from scrape import load_env, log, rpc

PAGE_URL = "https://www.reinfolib.mlit.go.jp/realEstatePrices/"
ZEN2HAN = str.maketrans("０１２３４５６７８９", "0123456789")


def download(city: str, frm: str, to: str) -> list[dict]:
    """검색 페이지에서 조건을 고르고 [ダウンロード] 버튼을 누른 응답을 받는다.

    다운로드 요청은 사이트 화면을 통해서만 받아들여진다(직접 호출은 401).
    자동화가 잦아지면 공식 API 키를 신청해 ex-api 를 쓰는 편이 맞다.
    """
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(locale="ja-JP")
        page.goto(PAGE_URL, wait_until="networkidle")
        page.select_option('select[name="cmbPrefectures"]', city[:2])
        page.wait_for_selector(f'select[name="cmbCitys"] option[value="{city}"]', state="attached")
        page.select_option('select[name="cmbCitys"]', city)
        page.select_option('select[name="cmbKind"]', "used")
        # 아직 공개되지 않은 분기를 지정하면 선택이 안 되므로 공개 범위로 맞춘다
        avail = sorted(page.eval_on_selector_all(
            'select[name="cmbSeasonTo"] option', "els => els.map(e => e.value)"))
        frm, to = max(frm, avail[0]), min(to, avail[-1])
        page.select_option('select[name="cmbSeasonFrom"]', frm)
        page.select_option('select[name="cmbSeasonTo"]', to)
        page.wait_for_timeout(800)
        with page.expect_response(lambda r: "csv/transactionPrices" in r.url, timeout=180_000) as info:
            page.locator('button[name="btnDownloadList"]:visible').first.click()
        payload = info.value.json()
        browser.close()
    if payload.get("processing") or "body" not in payload:
        raise RuntimeError(f"다운로드 준비 안 됨: {str(payload)[:200]}")
    zf = zipfile.ZipFile(io.BytesIO(base64.b64decode(payload["body"])))
    rows: list[dict] = []
    for name in zf.namelist():
        if not name.lower().endswith(".csv"):
            continue
        raw = zf.read(name)
        for enc in ("cp932", "utf-8-sig"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        rows += list(csv.DictReader(io.StringIO(text)))
    return rows


def to_num(s):
    s = (s or "").translate(ZEN2HAN).replace(",", "").strip()
    m = re.search(r"\d+(\.\d+)?", s)
    return float(m.group()) if m else None


def built_year(s):
    """'2007年' / '平成19年' / '戦前' → 서기 연도"""
    s = (s or "").translate(ZEN2HAN)
    m = re.search(r"(\d{4})年", s)
    if m:
        return int(m.group(1))
    for era, base in (("令和", 2018), ("平成", 1988), ("昭和", 1925)):
        m = re.search(era + r"(\d+|元)年", s)
        if m:
            return base + (1 if m.group(1) == "元" else int(m.group(1)))
    return None


def period(s):
    """'2025年第1四半期' → (2025, 1)"""
    m = re.search(r"(\d{4})年第(\d)四半期", (s or "").translate(ZEN2HAN))
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def normalize(row: dict, city: str) -> dict | None:
    g = lambda *keys: next((row[k].strip() for k in keys if row.get(k, "").strip()), None)  # noqa: E731
    price = to_num(g("取引価格（総額）", "取引価格(総額)"))
    area = to_num(g("面積（㎡）", "面積(㎡)"))
    year, quarter = period(g("取引時期"))
    if not price or not area or not year:
        return None
    kind = g("価格情報区分") or ""
    return {
        "city_code": city,
        "ward": g("市区町村名"),
        "town": g("地区名"),
        "source_kind": "closed" if "成約" in kind else "survey",
        "year": year,
        "quarter": quarter,
        "price_man": round(price / 10000, 2),
        "area_sqm": area,
        "layout": unicodedata.normalize("NFKC", g("間取り") or "") or None,   # ３ＬＤＫ → 3LDK
        "built_year": built_year(g("建築年")),
        "structure": g("建物の構造"),
        "station": g("最寄駅：名称"),
        "walk_min": to_num(g("最寄駅：距離（分）")),
        "renovated": g("改装"),
        "purpose": g("今後の利用目的"),
        "note": g("取引の事情等"),
    }


def main() -> int:
    today = date.today()
    ap = argparse.ArgumentParser()
    ap.add_argument("--city", action="append", help="市区町村 코드 (기본 13103=港区)")
    ap.add_argument("--from", dest="frm", default=f"{today.year - 3}1")
    ap.add_argument("--to", default=f"{today.year}4")
    ap.add_argument("--inspect", action="store_true")
    args = ap.parse_args()

    load_env()
    for city in args.city or ["13103"]:
        raw = download(city, args.frm, args.to)
        log(f"city {city}: {len(raw)}행 다운로드 ({args.frm}~{args.to})")
        if args.inspect:
            print(json.dumps(list(raw[0].keys()), ensure_ascii=False))
            for r in raw[:2] + raw[-1:]:
                print(json.dumps(r, ensure_ascii=False))
            continue
        rows = [n for n in (normalize(r, city) for r in raw) if n]
        res = rpc("ingest_transactions", p_source="mlit", p_city_code=city, p_from=int(args.frm), p_to=int(args.to), p_rows=rows)
        log(f"city {city}: {res}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
