"""kencorp.co.jp 매매 매물 샘플 스크래퍼 (컬럼 파악용).

흐름:
  1. 검색결과 페이지를 열고, 페이지가 스스로 호출하는 내부 API
     (/_api/search/result/) 응답을 가로채 건물+호실 목록(JSON)을 얻는다.
  2. 호실별 상세 페이지(/housing/properties/<bldg>/<prop>/)를 열어
     th/td 스펙 테이블을 그대로 key/value로 수집한다.

사용:
  poetry run python scrape_sample.py            # 미나토구 5건
  poetry run python scrape_sample.py --limit 10 --district 12
"""

from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import Page, sync_playwright

BASE = "https://www.kencorp.co.jp"
SEARCH_URL = (
    BASE + "/housing/buy/search/result/"
    "?search_by=district&search_type=buy&page={page}&per_page={per_page}"
    "&districts={district}&sort_key=_created_at"
)
API_PATH = "/_api/search/result/"
DELAY_SEC = 2.0  # 요청 간 간격 (서버 부담 방지)

# 상세 페이지 DOM 추출: th/td 테이블 + 제목/코멘트/이미지
DETAIL_JS = r"""
() => {
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const spec = {};
  for (const tr of document.querySelectorAll('table tr')) {
    const th = tr.querySelector('th'), td = tr.querySelector('td');
    if (!th || !td) continue;
    const key = clean(th.innerText).replace(/\*$/, '');
    if (key && !(key in spec)) spec[key] = clean(td.innerText);
  }
  const images = [...new Set(
    [...document.querySelectorAll('img')]
      .map(i => i.getAttribute('src') || i.dataset.src || '')
      .filter(s => /\/images\/(property|building)\//.test(s))
  )];
  const meta = n => document.querySelector(`meta[name="${n}"]`)?.content || null;
  return {
    title: document.title,
    h1: clean(document.querySelector('h1')?.innerText),
    meta_description: meta('description'),
    spec,
    images,
  };
}
"""


def fetch_listing(page: Page, district: str, page_no: int, per_page: int) -> dict:
    """검색결과 페이지를 열고 내부 API 응답(JSON)을 가로챈다."""
    url = SEARCH_URL.format(page=page_no, per_page=per_page, district=district)
    with page.expect_response(
        lambda r: API_PATH in r.url and r.status == 200, timeout=30_000
    ) as resp_info:
        page.goto(url, wait_until="domcontentloaded")
    return resp_info.value.json()


def flatten_units(listing: dict) -> list[dict]:
    """건물 > 호실 중첩 구조를 호실 1행 단위로 편다."""
    rows = []
    for b in listing.get("buildings", []):
        bldg = {f"bldg_{k}" if not k.startswith("bldg_") else k: v
                for k, v in b.items() if k not in ("properties", "image_path")}
        bldg["bldg_image_count"] = len(b.get("image_path") or [])
        for p in b.get("properties", []):
            unit = {}
            images = []
            for k, v in p.items():
                if k.startswith("image_caption_"):
                    continue
                if k.startswith("image_") and k[6:].isdigit():
                    if v:
                        images.append({"url": v, "caption": p.get(f"image_caption_{k[6:]}", "")})
                    continue
                unit[f"prop_{k}"] = v
            unit["prop_images"] = images
            rows.append({**bldg, **unit})
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--district", default="12", help="区 코드 (12 = 港区)")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--out", default="data/sample_minato.json")
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args()

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not args.headed)
        ctx = browser.new_context(locale="ja-JP", timezone_id="Asia/Tokyo")
        page = ctx.new_page()

        listing = fetch_listing(page, args.district, page_no=1, per_page=10)
        print(f"검색결과: 건물 {listing.get('bldg_count')}동 / 매물 {listing.get('prop_count')}건")

        # 건물당 1건씩 골라 다양한 건물을 보도록 한다
        seen, units = set(), []
        for u in flatten_units(listing):
            if u["bldg_code"] in seen:
                continue
            seen.add(u["bldg_code"])
            units.append(u)
            if len(units) >= args.limit:
                break

        records = []
        for u in units:
            time.sleep(DELAY_SEC)
            url = BASE + u["prop_url"]
            page.goto(url, wait_until="domcontentloaded")
            page.wait_for_selector("table tr th", timeout=15_000)
            detail = page.evaluate(DETAIL_JS)
            records.append({
                "scraped_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "source_url": url,
                "list": u,
                "detail": detail,
            })
            print(f"  ✓ {detail['h1'] or detail['title']}  ({len(detail['spec'])}개 스펙 항목)")

        browser.close()

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(records, ensure_ascii=False, indent=2))
    print(f"\n저장: {out} ({len(records)}건)")

    # ---- 컬럼 요약 ----
    def summarize(label: str, dicts: list[dict]) -> None:
        keys: dict[str, list] = {}
        for d in dicts:
            for k, v in d.items():
                keys.setdefault(k, []).append(v)
        print(f"\n[{label}] {len(keys)}개 필드")
        for k, vals in keys.items():
            filled = [v for v in vals if v not in ("", None, [], 0, "0.00")]
            sample = json.dumps(filled[0], ensure_ascii=False)[:70] if filled else "-"
            print(f"  {k:<28} {len(filled)}/{len(dicts)}  {sample}")

    summarize("목록 API", [r["list"] for r in records])
    summarize("상세 스펙 테이블", [r["detail"]["spec"] for r in records])


if __name__ == "__main__":
    main()
