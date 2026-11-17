"""kencorp.co.jp 매매 매물 증분 스크래퍼 → Supabase.

매 실행:
  1. 구(ward) 단위로 목록 API 전체를 받는다 (100동/호출, 가볍다).
  2. ingest_listings RPC 가 DB와 비교해 신규/변경/재등록/소멸을 기록하고,
     상세 페이지가 필요한 매물(신규·변경·30일 경과)만 돌려준다.
  3. 그 매물만 상세 페이지를 방문해 ingest_details 로 반영한다.
  4. 신규 매물이 있었으면 세부 에리어(麻布・広尾 등) 소속을 갱신한다.

사용:
  poetry run python scrape.py                 # 港区(12)
  poetry run python scrape.py --ward 12 --ward 13
  poetry run python scrape.py --areas         # 에리어 소속 강제 갱신
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from playwright.sync_api import Page, sync_playwright

SOURCE = "kencorp"
BASE = "https://www.kencorp.co.jp"
DEFAULT_WARDS = ["12", "2", "8"]  # 港区, 渋谷区, 新宿区 (사이트의 구 코드)
PER_PAGE = 100
DELAY_SEC = 1.5
DETAIL_BATCH = 20
ZEN2HAN = str.maketrans("０１２３４５６７８９", "0123456789")


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


# ------------------------------------------------------------------ supabase
def load_env() -> None:
    env = Path(__file__).with_name(".env")
    if env.exists():
        for line in env.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def rpc(fn: str, **params) -> dict:
    body = json.dumps({"p_token": os.environ["INGEST_TOKEN"], "p_source": SOURCE, **params})
    req = urllib.request.Request(
        f"{os.environ['SUPABASE_URL']}/rest/v1/rpc/{fn}",
        data=body.encode(),
        headers={"apikey": os.environ["SUPABASE_KEY"], "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"RPC {fn} failed: {e.code} {e.read().decode()[:500]}") from None


# ------------------------------------------------------------------ list API
def api_fetch(page: Page, query: str, deal: str = "buy") -> dict:
    """사이트 페이지 컨텍스트에서 내부 목록 API를 호출한다. deal = buy | rent"""
    url = f"/_api/search/result/?search_type={deal}&sort_key=_created_at&per_page={PER_PAGE}&{query}"
    for attempt in range(3):
        try:
            data = page.evaluate("u => fetch(u).then(r => r.json())", url)
            if data.get("error_code"):
                raise RuntimeError(f"API error_code={data['error_code']}")
            return data
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            log(f"  재시도 ({e})")
            time.sleep(5)
    raise AssertionError


def fetch_all_buildings(page: Page, query: str, deal: str = "buy") -> list[dict]:
    first = api_fetch(page, f"{query}&page=1", deal)
    buildings = list(first.get("buildings") or [])
    pages = math.ceil((first.get("bldg_count") or 0) / PER_PAGE)
    for n in range(2, pages + 1):
        time.sleep(DELAY_SEC)
        buildings += api_fetch(page, f"{query}&page={n}", deal).get("buildings") or []
    return buildings


def num(v):
    try:
        f = float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return None
    return f


def parse_address(addr: str) -> dict:
    """東京都港区芝浦４ → ward=港区, town=芝浦, chome=4"""
    s = (addr or "").translate(ZEN2HAN).strip()
    m = re.match(r"^(?:東京都|北海道|(?:京都|大阪)府|.{2,3}県)?(.+?[区市郡])(.*?)(\d+)?$", s)
    if not m:
        return {"ward": None, "town": None, "chome": None, "address_key": s or None}
    ward, town, chome = m.group(1), m.group(2) or None, m.group(3)
    return {
        "ward": ward,
        "town": town,
        "chome": int(chome) if chome else None,
        "address_key": f"{ward}{town or ''}{chome or ''}",
    }


def normalize(buildings: list[dict], deal: str = "buy") -> list[dict]:
    """deal='rent' 이면 price_man 은 월 임대료(万円)다 (API는 엔 단위로 준다)."""
    out = []
    for b in buildings:
        units = []
        for p in b.get("properties") or []:
            images = [
                {"url": p[f"image_{i}"], "caption": p.get(f"image_caption_{i}") or ""}
                for i in range(1, 21)
                if p.get(f"image_{i}")
            ]
            floor = num(p.get("floor"))
            admin = num(p.get("admin_cost"))
            y = num(p.get("yield"))
            price, sqm = num(p.get("price")), num(p.get("footprint"))
            if deal == "rent" and price is not None:
                price = round(price / 10000, 2)
            tsubo = num(p.get("footprint_t")) or (round(sqm / 3.305785, 2) if sqm else None)
            units.append({
                "prop_code": p["code"],
                "wing": p.get("building_no") or None,
                "room_no": p.get("room") or None,
                "floor": int(floor) if floor is not None else None,
                "layout": p.get("layout") or None,
                "area_sqm": sqm,
                "area_tsubo": tsubo,
                "price_man": price,
                "admin_fee_yen": int(admin) if admin is not None else None,
                "yield_pct": y if y else None,
                "usage": ",".join(p.get("office_usefor") or []) or None,
                "labels": p.get("labels") or [],
                "icons": p.get("addition_icons") or [],
                "pending": p.get("pending") or None,
                "url": p.get("url"),
                "layout_image": p.get("layout_image") or None,
                "images": images,
            })
        if not units:
            continue
        out.append({
            "bldg_code": b["bldg_code"],
            "name": b.get("bldg_name") or "",
            "kind": b.get("bldg_kind"),
            "address": b.get("address"),
            **parse_address(b.get("address")),
            "lat": num(b.get("bldg_lat")),
            "lng": num(b.get("bldg_lng")),
            "route_summary": b.get("route"),
            "completed_ym": b.get("complete_date") or None,
            "url": b.get("url"),
            "units": units,
        })
    return out


# ------------------------------------------------------------------ details
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
  return spec;
}
"""


def yen(s):
    m = re.search(r"([\d,]+)\s*円", s or "")
    return int(m.group(1).replace(",", "")) if m else None


def jdate(s):
    m = re.search(r"(\d{4})年(\d{1,2})月(\d{1,2})日", s or "")
    return f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}" if m else None


def items(s):
    return [x.strip() for x in re.split(r"[、,]", s or "") if x.strip()]


def after_slash(s):
    parts = (s or "").split("/", 1)
    return parts[1].strip() or None if len(parts) == 2 else None


def first_int(pattern, s):
    m = re.search(pattern, s or "")
    return int(m.group(1).replace(",", "")) if m else None


def parse_detail(prop_code: str, spec: dict) -> dict:
    g = lambda k: spec.get(k) or None  # noqa: E731
    floors = g("階建 / 所在階") or ""
    struct = g("構造 / 総戸数") or ""
    school = re.sub(r"\s*通学経路\s*$", "", g("通学区域小学校") or "") or None
    return {
        "prop_code": prop_code,
        "spec_raw": spec,
        "listing": {
            "repair_reserve_yen": yen(g("修繕積立金")),
            "other_fee": g("その他費用"),
            "orientation": after_slash(g("間取り / 方位")),
            "balcony": g("バルコニー関連"),
            "occupancy": g("現況"),
            "handover": g("引渡時期"),
            "transaction_type": g("取引形態"),
            "parking": g("駐車場"),
            "features": items(g("特徴")),
            "equipment": items(g("部屋設備")),
            "remarks": g("備考"),
            "info_updated_on": jdate(g("情報更新日")),
            "next_update_on": jdate(g("次回更新予定日")),
        },
        "building": {
            "access": g("交通/駅徒歩"),
            "structure": struct.split("/")[0].strip() or None,
            "total_units": first_int(r"([\d,]+)\s*戸", struct),
            "floors_above": first_int(r"地上\s*(\d+)\s*階", floors),
            "floors_below": first_int(r"地下\s*(\d+)\s*階", floors),
            "land_right": g("敷地権利"),
            "builder": g("施工業者"),
            "developer": g("分譲会社"),
            "mgmt_company": g("管理会社"),
            "mgmt_type": g("管理 / 勤務形態"),
            "school": school,
            # 빈 목록이면 DB의 기존 값을 유지한다 (null 을 보내면 RPC가 실패)
            "facilities": items(g("建物設備・施設")),
        },
    }


def scrape_details(page: Page, todo: list[dict]) -> int:
    done, batch = 0, []

    def flush():
        nonlocal done, batch
        if batch:
            done += rpc("ingest_details", p_details=batch)["updated"]
            batch = []

    for i, t in enumerate(todo, 1):
        time.sleep(DELAY_SEC)
        try:
            page.goto(BASE + t["url"], wait_until="domcontentloaded", timeout=30_000)
            page.wait_for_selector("table tr th", timeout=10_000)
            spec = page.evaluate(DETAIL_JS)
            if "価格" not in spec and "住所" not in spec:
                raise RuntimeError("스펙 표 없음")
            batch.append(parse_detail(t["prop_code"], spec))
        except Exception as e:  # noqa: BLE001
            log(f"  ! 상세 실패 {t['prop_code']}: {str(e).splitlines()[0][:100]}")
        if len(batch) >= DETAIL_BATCH:
            flush()
            log(f"  상세 {i}/{len(todo)}")
    flush()
    return done


# ------------------------------------------------------------------ areas
AREAS_JS = r"""
() => {
  const seen = new Map();
  for (const i of document.querySelectorAll('input[name="areas"]')) {
    if (seen.has(i.value)) continue;
    const name = (i.closest('label')?.innerText || '').trim();
    const grp = i.closest('.js-filter')?.querySelector('.js-checkall')?.closest('label');
    const group = (grp?.innerText || '').trim().split('\n')[0] || null;
    if (name) seen.set(i.value, {code: i.value, name, group_name: group});
  }
  return [...seen.values()];
}
"""


def scrape_areas(page: Page, deal: str = "buy") -> int:
    page.goto(BASE + "/housing/buy/search/area/", wait_until="domcontentloaded")
    areas = page.evaluate(AREAS_JS)
    log(f"에리어 {len(areas)}개 소속 갱신 ({deal})")
    for a in areas:
        time.sleep(DELAY_SEC)
        try:
            blds = fetch_all_buildings(page, f"search_by=area&areas={a['code']}", deal)
        except Exception as e:  # noqa: BLE001  일부 에리어는 임대 검색에서 빈 응답을 준다
            log(f"  ! 에리어 {a['code']} {a['name']} 건너뜀: {str(e).splitlines()[0][:80]}")
            blds = []
        a["bldg_codes"] = [b["bldg_code"] for b in blds]
    source = SOURCE if deal == "buy" else f"{SOURCE}-rent"
    return rpc("ingest_areas", p_source=source, p_areas=areas)["links_added"]


# ------------------------------------------------------------------ main
def block_heavy(route):
    r = route.request
    if r.resource_type in ("image", "media", "font") or "kencorp.co.jp" not in r.url:
        return route.abort()
    return route.continue_()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ward", action="append", help="구 코드 (기본: 港区 12, 渋谷区 2, 新宿区 8). 여러 번 지정 가능")
    ap.add_argument("--deal", choices=["buy", "rent", "both"], default="both", help="매매/임대")
    ap.add_argument("--areas", action="store_true", help="에리어 소속을 강제 갱신")
    ap.add_argument("--max-details", type=int, default=2000)
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args()
    wards = args.ward or DEFAULT_WARDS
    deals = ["buy", "rent"] if args.deal == "both" else [args.deal]

    load_env()
    run_date = datetime.now(ZoneInfo("Asia/Tokyo")).date().isoformat()

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=not args.headed)
        ctx = browser.new_context(locale="ja-JP", timezone_id="Asia/Tokyo")
        ctx.route("**/*", block_heavy)
        page = ctx.new_page()
        page.goto(BASE + "/housing/buy/", wait_until="domcontentloaded")

        new_deals, todo = set(), []
        for ward in wards:
            for deal in deals:
                raw = fetch_all_buildings(page, f"search_by=district&districts={ward}", deal)
                payload = normalize(raw, deal)
                n_units = sum(len(b["units"]) for b in payload)
                log(f"ward {ward} {deal}: 건물 {len(payload)}동 / 매물 {n_units}건 수집")
                res = rpc("ingest_listings", p_source=SOURCE if deal == "buy" else f"{SOURCE}-rent",
                          p_ward_code=ward, p_run_date=run_date, p_buildings=payload)
                need = res.pop("need_detail")
                if res["new"] > 0:
                    new_deals.add(deal)
                if deal == "buy":       # 임대는 목록 정보만 쓴다 (상세 페이지 방문 안 함)
                    log(f"ward {ward} {deal}: {res} / 상세 필요 {len(need)}건")
                    todo += need
                else:
                    log(f"ward {ward} {deal}: {res}")
                time.sleep(DELAY_SEC)

        for deal in deals:
            if deal in new_deals or args.areas:
                log(f"에리어 연결 추가 {scrape_areas(page, deal)}건 ({deal})")

        todo = todo[: args.max_details]
        if todo:
            log(f"상세 페이지 {len(todo)}건 수집 시작")
            log(f"상세 반영 {scrape_details(page, todo)}건")

        browser.close()
    log("완료")
    return 0


if __name__ == "__main__":
    sys.exit(main())
