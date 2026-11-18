"""매일 추천 매물 3건을 LINE 으로 보낸다.

조건(기본): 港区 · 매매 · 2억 엔 이상 4억 엔 미만 · 전용 70㎡ 이상 · 게재 중.
정렬: 주변보다 평단가가 얼마나 싼가. 같은 동네·같은 평형대 매물의 평단가 중앙값과 비교하고,
      그 동네에 같은 평형대 매물이 4건 미만이면 동네 전체 중앙값(5건 이상)과 비교한다.
매일 3건: 싼 순으로 줄을 세운 뒤 날짜에 따라 3건씩 넘겨 가며 보낸다(끝까지 가면 처음으로).
      매물은 하루 사이에 거의 바뀌지 않아서, 넘기지 않으면 매일 같은 3건이 간다.

  poetry run python line_daily.py            # 보낼 내용만 출력 (전송 안 함)
  poetry run python line_daily.py --send     # LINE 공식 계정의 친구 전원에게 전송

전송에는 환경변수 LINE_CHANNEL_ACCESS_TOKEN 이 필요하다. LINE_TO(그룹·사용자 ID)가 있으면 그곳에만 보낸다.
"""
import argparse
import datetime
import json
import os
import statistics
import sys
import urllib.parse
import urllib.error
import urllib.request
from pathlib import Path


def load_env() -> None:
    """로컬 실행용: .env 를 읽는다 (scrape.py 와 같은 방식. Playwright 없이 돌도록 따로 둔다)."""
    env = Path(__file__).with_name(".env")
    if env.exists():
        for line in env.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


PAGE = "https://shokubase.github.io/tokyo-realestate/"
TSUBO = 3.305785
BANDS = [(0, 50), (50, 70), (70, 100), (100, 150), (150, 1e9)]
COLS = ("id,bldg_code,bldg_name,ward,town,chome,floor,layout,area_sqm,price_man,price_per_tsubo_man,"
        "completed_year,route_summary,is_new,is_price_changed,land_right,first_seen")


def fetch(ward: str) -> list[dict]:
    """그 구의 게재 중 매매 매물 전부 (PostgREST 는 한 번에 1,000행까지라 나눠 받는다)."""
    rows, step = [], 1000
    q = urllib.parse.urlencode({"select": COLS, "deal_type": "eq.buy", "is_active": "eq.true",
                                "ward": f"eq.{ward}", "order": "id"})
    while True:
        req = urllib.request.Request(
            f"{os.environ['SUPABASE_URL']}/rest/v1/listings_enriched?{q}",
            headers={"apikey": os.environ["SUPABASE_KEY"], "Range": f"{len(rows)}-{len(rows) + step - 1}"})
        with urllib.request.urlopen(req, timeout=60) as r:
            part = json.load(r)
        rows += part
        if len(part) < step:
            return rows


def band(r: dict) -> int:
    return next(i for i, (lo, hi) in enumerate(BANDS) if lo <= r["area_sqm"] < hi)


def rank(rows: list[dict], pmin: float, pmax: float, amin: float) -> list[dict]:
    ok = [r for r in rows if r["price_per_tsubo_man"] and r["area_sqm"] and r["town"]]
    for r in ok:
        for k in ("price_man", "area_sqm", "price_per_tsubo_man"):
            r[k] = float(r[k])
    by_town, by_band = {}, {}
    for r in ok:
        by_town.setdefault(r["town"], []).append(r["price_per_tsubo_man"])
        by_band.setdefault((r["town"], band(r)), []).append(r["price_per_tsubo_man"])
    out = []
    for r in ok:
        if not (pmin <= r["price_man"] < pmax and r["area_sqm"] >= amin):
            continue
        b, t = by_band[(r["town"], band(r))], by_town[r["town"]]
        if len(b) >= 4:
            base, r["basis"], r["n"] = statistics.median(b), "같은 동네·같은 평형대", len(b)
        elif len(t) >= 5:
            base, r["basis"], r["n"] = statistics.median(t), "같은 동네", len(t)
        else:
            continue                                   # 비교할 주변 매물이 너무 적다
        r["disc"] = (1 - r["price_per_tsubo_man"] / base) * 100
        out.append(r)
    # 주변보다 5% 이상 싼 것만 후보로 둔다 (전부 돌리면 대부분의 날에 "주변보다 비싼" 매물이 간다)
    return sorted((r for r in out if r["disc"] >= 5), key=lambda r: -r["disc"])


def pick(ranked: list[dict], day: int, n: int = 3) -> list[tuple[int, dict]]:
    """날짜에 따라 n건씩 넘겨 가며 고른다. 하루에 같은 건물은 한 번만."""
    if not ranked:
        return []
    start, out, seen = (day * n) % len(ranked), [], set()
    for i in range(len(ranked)):
        j = (start + i) % len(ranked)
        r = ranked[j]
        if r["bldg_code"] in seen:
            continue
        seen.add(r["bldg_code"])
        out.append((j + 1, r))
        if len(out) == n:
            break
    return out


def oku(man: float) -> str:
    o, m = divmod(round(man), 10000)
    return f"{o}억" + (f" {m:,}만" if m else "") + " 엔"


def message(picks, total: int, today: datetime.date, cond: str) -> str:
    lines = [f"🏠 오늘의 추천 매물 ({today:%m/%d})", cond, f"주변보다 5% 이상 싼 {total}건 중 순위 (매일 3건씩 차례로)"]
    for no, r in picks:
        tags = [t for t, on in (("신착", r["is_new"]), ("가격 개정", r["is_price_changed"])) if on]
        warn = []
        if r["completed_year"] and r["completed_year"] <= 1981:
            warn.append("1981년 이전 준공(구 내진 기준)")
        if r["land_right"] and not r["land_right"].startswith("所有権"):
            warn.append("토지 소유권 아님 (" + r["land_right"].split()[0] + ")")
        where = r["town"] + (f"{r['chome']}丁目" if r["chome"] else "")
        unit = " · ".join(x for x in (f"{r['floor']}층" if r["floor"] is not None else "", r["layout"] or "",
                                      f"{r['area_sqm']:g}㎡({r['area_sqm'] / TSUBO:.1f}평)") if x)
        cmp_ = (f"{r['basis']} 매물 {r['n']}건의 평단가 중앙값보다 {r['disc']:.0f}% 낮음" if r["disc"] > 0
                else f"{r['basis']} 매물 {r['n']}건의 평단가 중앙값보다 {-r['disc']:.0f}% 높음")
        lines += ["", f"{no}위. {r['bldg_name']}" + (f" [{', '.join(tags)}]" if tags else ""),
                  f"{where} · {unit}",
                  f"{oku(r['price_man'])} (평당 {r['price_per_tsubo_man']:,.0f}만 엔)",
                  f"→ {cmp_}"]
        if r["completed_year"] or r["route_summary"]:
            lines.append(" · ".join(x for x in (f"{r['completed_year']}년 준공" if r["completed_year"] else "",
                                                r["route_summary"] or "") if x))
        if warn:
            lines.append("⚠ " + ", ".join(warn))
        lines.append(f"{PAGE}?id={r['id']}")
    lines += ["", "호가 기준이고 싼 데는 이유가 있을 수 있습니다. 상세와 원문을 꼭 확인하세요."]
    return "\n".join(lines)


def send(text: str) -> None:
    to = os.environ.get("LINE_TO")
    body = {"messages": [{"type": "text", "text": text[:4900]}]}
    if to:
        body["to"] = to
    req = urllib.request.Request(
        f"https://api.line.me/v2/bot/message/{'push' if to else 'broadcast'}",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {os.environ['LINE_CHANNEL_ACCESS_TOKEN']}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print("LINE 전송 완료:", r.status)
    except urllib.error.HTTPError as e:
        sys.exit(f"LINE 전송 실패 {e.code}: {e.read().decode(errors='replace')[:300]}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ward", default="港区")
    ap.add_argument("--price-min", type=float, default=2.0, help="억 엔, 이상")
    ap.add_argument("--price-max", type=float, default=4.0, help="억 엔, 미만")
    ap.add_argument("--area-min", type=float, default=70)
    ap.add_argument("--send", action="store_true")
    ap.add_argument("--day", type=int, help="미리보기용: 며칠째 순번인지 직접 지정")
    a = ap.parse_args()
    load_env()
    today = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).date()
    ranked = rank(fetch(a.ward), a.price_min * 10000, a.price_max * 10000, a.area_min)
    picks = pick(ranked, a.day if a.day is not None else today.toordinal())
    if not picks:
        print("조건에 맞는 매물이 없습니다.")
        return
    cond = f"{a.ward} · {a.price_min:g}억~{a.price_max:g}억 엔 미만 · {a.area_min:g}㎡ 이상"
    text = message(picks, len(ranked), today, cond)
    print(text)
    if a.send:
        if not os.environ.get("LINE_CHANNEL_ACCESS_TOKEN"):
            sys.exit("LINE_CHANNEL_ACCESS_TOKEN 이 없어 전송하지 못했습니다.")
        send(text)


if __name__ == "__main__":
    main()
