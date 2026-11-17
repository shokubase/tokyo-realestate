"""AI 검색(Edge Function `chat`) 시험. 질문을 보내고 해석된 조건을 출력한다.

  poetry run python test_chat.py                 # 기본 질문 세트
  poetry run python test_chat.py "아자부 3억 이하"
"""

import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ENV = dict(l.split("=", 1) for l in Path(__file__).with_name(".env").read_text().splitlines() if "=" in l)

QUESTIONS = [
    "아자부 지역에서 평당가격이 싼 매물",
    "롯폰기 쪽 80평방미터에 3억 이하인 매물",
    "수익률이 3% 이상인 것",
    "매물가격 대비 월세가 싼 곳",
    "히로오 지역에서 80평방미터 근방 집 월세 데이터 전부 리스트업해줘",
    "시로카네 2LDK 월세 50만 이하 싼 순으로 5개만",
    "오늘 날씨 어때?",
]


def ask(q: str) -> dict:
    req = urllib.request.Request(
        ENV["SUPABASE_URL"] + "/functions/v1/chat",
        data=json.dumps({"password": ENV["CHAT_PASSWORD"], "question": q}).encode(),
        headers={"Content-Type": "application/json"},
    )
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            out = json.loads(r.read())
    except urllib.error.HTTPError as e:
        out = {"http": e.code, **json.loads(e.read() or b"{}")}
    out["sec"] = round(time.time() - t, 1)
    return out


for q in sys.argv[1:] or QUESTIONS:
    res = ask(q)
    print(f"\nQ: {q}   ({res['sec']}s)")
    if "query" not in res:
        print("  !", {k: v for k, v in res.items() if k != "sec"})
        continue
    query = res["query"]
    shown = {k: v for k, v in query.items() if v not in (None, [], "") and k != "reply"}
    print("  ", json.dumps(shown, ensure_ascii=False))
    print("   reply:", query["reply"])
    u = res.get("usage") or {}
    print(f"   model={res.get('model')} in={u.get('input_tokens')} out={u.get('output_tokens')}")
