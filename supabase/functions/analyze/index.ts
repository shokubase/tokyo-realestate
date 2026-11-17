// 깊이 분석: Claude 가 읽기 전용 SQL 도구로 DB를 직접 조회하면서 답을 만든다.
//   chat 함수(질문 → 필터 조건, 한 번 호출)와 달리 여러 번 조회하고 결과를 보고 판단한다.
//   조회는 ai_select RPC(공개 읽기 권한, SELECT 만, 3초 제한, 200행)로만 가능하다.
// 필요한 시크릿: ANTHROPIC_API_KEY
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk";

const MODEL = "claude-haiku-5-5";
const MAX_STEPS = 8;              // 모델 호출 횟수 상한
const MAX_RESULT_CHARS = 12000;   // 조회 결과를 모델에 돌려줄 때의 상한
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function rpc(fn: string, body: unknown) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SB_ANON, Authorization: `Bearer ${SB_ANON}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return { ok: r.ok, data: await r.json().catch(() => null) };
}

async function runSql(password: string, sql: string): Promise<{ text: string; error: boolean }> {
  const { ok, data } = await rpc("ai_select", { p_password: password, p_sql: sql });
  if (!ok) return { text: `SQL error: ${data?.message ?? "request failed"} (3초 제한을 넘었을 수 있다. 더 가벼운 질의로 바꿔라)`, error: true };
  if (data?.error) return { text: `SQL error: ${data.error}`, error: true };
  let text = JSON.stringify(data?.rows ?? []);
  if (text.length > MAX_RESULT_CHARS) {
    text = text.slice(0, MAX_RESULT_CHARS) + ` …(잘림: 결과가 너무 크다. 컬럼을 줄이거나 집계/limit 을 써라)`;
  }
  return { text, error: false };
}

const tools: Anthropic.Tool[] = [
  {
    name: "run_sql",
    description:
      "PostgreSQL SELECT 질의 하나를 실행하고 결과 행을 JSON 으로 돌려준다. 읽기 전용이고, 세미콜론 없이 한 문장만, 3초 안에 끝나야 하며 최대 200행이 돌아온다. 필요한 컬럼만 고르고 가능하면 SQL 안에서 집계한다.",
    input_schema: {
      type: "object",
      properties: { sql: { type: "string", description: "SELECT 또는 WITH 로 시작하는 질의 한 문장" } },
      required: ["sql"],
      additionalProperties: false,
    },
  },
  {
    name: "show_listings",
    description:
      "사용자 화면에 매물 카드로 띄울 매물을 지정한다. ai_listings.id 값을 관련도 높은 순서로 최대 40개 넘긴다. 매물을 찾아 달라는 질문이면 최종 답변 전에 반드시 한 번 호출한다.",
    input_schema: {
      type: "object",
      properties: { ids: { type: "array", items: { type: "integer" }, description: "ai_listings.id 목록" } },
      required: ["ids"],
      additionalProperties: false,
    },
  },
];

const SYSTEM = (lang: "ko" | "ja") => `너는 도쿄 주거용 부동산 매물 DB를 분석해 가족의 질문에 답하는 분석가다.
run_sql 도구로 DB를 직접 조회해 사실을 확인한 뒤 답한다. 추측으로 숫자를 말하지 않는다.

## 데이터 (PostgreSQL)

### ai_listings — 매물 1행 = 1건 (가장 많이 쓴다)
id, deal_type('buy' 매매 | 'rent' 임대), is_active(지금 게재 중인지), ward(구: '港区','渋谷区','新宿区'), town(동네 한자, 예 '南麻布'), chome(丁目 숫자),
bldg_code(건물 코드: 같은 건물이면 같다. 매매와 임대를 이 값으로 잇는다), bldg_name, floor, room_no, layout(예 '2LDK'), orientation,
area_sqm(전용면적 ㎡), area_tsubo(坪), price_man(매매: 가격 万円 / 임대: 월 임대료 万円), price_per_tsubo_man(坪当 万円),
admin_fee_yen(월 관리비 円), repair_reserve_yen(월 수선적립금 円, 매매만), completed_year(준공 연도), total_units, floors_above, structure, land_right(토지 권리),
occupancy(현황: 空室/賃貸中 등), transaction_type, walk_min(가장 가까운 역 도보 분), route_summary, lat, lng,
is_new(사이트 신착 표시), is_price_changed(사이트 가격개정 표시), first_seen, last_seen, delisted_on(게재 종료일), area_names(세부 지역 이름 배열, 예 '麻布・広尾')

### transactions — 국토교통성 중고 맨션 실거래 (건물명 없음)
ward, town, source_kind('closed' 성약가격 | 'survey' 설문), year, quarter, period(예 20254 = 2025년 4분기), price_man(万円), area_sqm(5㎡ 단위 반올림), layout, built_year, structure, station, walk_min

### listing_events — 매물 변동 이력
listing_id(= ai_listings.id), observed_on, event('new','price_change','change','relisted','delisted','detail_change'), price_man, prev_price_man, changes(jsonb)

## 알아둘 것
- 특별한 말이 없으면 is_active 인 매물만 본다. 매매와 임대를 섞지 않도록 deal_type 을 항상 건다.
- 금액은 모두 엔이다. 1억 엔 = 10000 万円. 사용자가 "2억"이라고 하면 price_man 20000 이다. 원화로 말해도 엔으로 간주하고 답에서 그렇게 밝힌다.
- 표면 수익률 = 같은 건물(bldg_code) 임대 매물의 ㎡당 월 임대료 중앙값 × 매매 매물 면적 × 12 ÷ 매매가. 같은 건물에 임대가 없으면 계산하지 않는다.
- "주변보다 싸다"는 같은 town(필요하면 비슷한 면적대) 매물의 price_per_tsubo_man 중앙값과 비교한다. 중앙값은 percentile_cont(0.5) within group (order by …) 를 쓴다.
- 한글로 적힌 지명은 일본어 한자 표기로 바꿔 조회한다 (히로오 → 広尾, 아자부 → 이름에 '麻布' 가 들어가는 town).
- 데이터 수집은 최근에 시작돼 변동 이력(listing_events)은 아직 거의 없다. 이력이 필요한 질문이면 먼저 얼마나 쌓였는지 확인하고, 부족하면 그렇다고 답한다.
- DB에 없는 정보(학군 평판, 소음, 실제 내부 상태, 대출 가능 여부 등)는 없다고 말한다.

## 진행
1. 질의는 꼭 필요한 만큼만, 많아도 5~6번 안에 끝낸다. 한 질의에서 집계까지 끝내는 편이 좋다.
2. 질의가 오류를 내면 메시지를 읽고 고쳐 다시 실행한다.
3. 매물을 찾아 달라는 질문이면 show_listings 로 해당 매물 id 를 넘긴다.
4. 마지막에 답을 쓴다.

## 답변
- 반드시 ${lang === "ja" ? "일본어(です・ます체)" : "한국어"}로 쓴다.
- 짧게 쓴다. 결론을 먼저 한두 문장으로 말하고, 근거가 되는 숫자를 "- "로 시작하는 줄로 몇 개 적는다. 표나 마크다운 강조(**)는 쓰지 않는다.
- 어떤 기준으로 골랐는지(임계값, 비교 대상)를 밝힌다. 표본이 적거나 한계가 있으면 한 줄로 알린다.
- 지명과 건물명은 DB의 표기 그대로 쓴다. 한글로 음을 옮겨 적지 않는다.
- 사실과 비교만 말한다. 사라거나 사지 말라는 식의 투자 판단은 하지 않는다. 호가 기준이라는 점은 필요할 때만 한 번 말한다.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let body: { password?: string; question?: string; lang?: string; model?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const question = (body.question ?? "").trim();
  const password = body.password ?? "";
  if (!question || question.length > 800) return json({ error: "bad_request" }, 400);

  const gate = (await rpc("chat_gate", { p_password: password })).data;
  if (gate !== "ok") return json({ error: gate ?? "error" }, gate === "bad_password" ? 401 : 429);
  if (!Deno.env.get("ANTHROPIC_API_KEY")) return json({ error: "no_api_key" }, 503);

  const client = new Anthropic();
  // 기본은 Haiku. "정밀"을 고르면 Sonnet 5.5 로 돌린다 (입출력 단가가 모두 Haiku 의 20배).
  const sonnet = body.model === "sonnet";
  const system = SYSTEM(body.lang === "ja" ? "ja" : "ko");
  // deno-lint-ignore no-explicit-any
  const callModel = (msgs: any) =>
    sonnet
      ? client.beta.messages.create({
          model: "claude-sonnet-5-5",
          max_tokens: 16000,
          // 안전 분류기가 요청을 거절하면 API가 다른 모델로 같은 요청을 이어서 처리한다
          betas: ["server-side-fallback-2026-07-01"],
          fallbacks: "default",
          output_config: { effort: "medium" },
          system,
          tools,
          messages: msgs,
        })
      : client.messages.create({ model: MODEL, max_tokens: 16000, system, tools, messages: msgs });
  const costMult = sonnet ? 20 : 1;   // 사용량 집계는 Haiku 단가 기준이라 Sonnet 은 토큰을 20배로 적는다
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: question }];
  const queries: { sql: string; ok: boolean }[] = [];
  let ids: number[] = [];
  let answer = "";
  let inTok = 0, outTok = 0;

  try {
    for (let step = 0; step < MAX_STEPS; step++) {
      // deno-lint-ignore no-explicit-any
      const response: any = await callModel(messages);
      const u = response.usage;
      inTok += (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      outTok += u.output_tokens ?? 0;

      if (response.stop_reason === "refusal") return json({ error: "no_answer" }, 502);
      // deno-lint-ignore no-explicit-any
      const text = response.content.flatMap((b: any) => (b.type === "text" ? [b.text] : [])).join("\n").trim();
      if (response.stop_reason !== "tool_use") { answer = text; break; }

      // 도구 호출 실행. 결과는 모두 한 번의 user 메시지로 돌려준다.
      messages.push({ role: "assistant", content: response.content });
      const results: Anthropic.ContentBlockParam[] = [];
      for (const b of response.content) {
        if (b.type !== "tool_use") continue;
        const input = (b.input ?? {}) as { sql?: unknown; ids?: unknown };
        if (b.name === "run_sql") {
          const sql = String(input.sql ?? "");
          const out = await runSql(password, sql);
          queries.push({ sql, ok: !out.error });
          results.push({ type: "tool_result", tool_use_id: b.id, content: out.text, is_error: out.error });
        } else if (b.name === "show_listings") {
          ids = (Array.isArray(input.ids) ? input.ids : []).map(Number).filter(Number.isInteger).slice(0, 60);
          results.push({ type: "tool_result", tool_use_id: b.id, content: `ok (${ids.length} listings will be shown)` });
        } else {
          results.push({ type: "tool_result", tool_use_id: b.id, content: "unknown tool", is_error: true });
        }
      }
      if (step === MAX_STEPS - 2) {
        results.push({ type: "text", text: "조회 횟수 한도에 가까워졌다. 더 조회하지 말고 지금까지의 결과로 답을 써라." });
      }
      messages.push({ role: "user", content: results });
    }
  } catch (e) {
    await rpc("chat_record", { p_password: password, p_in: inTok * costMult, p_out: outTok * costMult });
    if (e instanceof Anthropic.AuthenticationError) return json({ error: "bad_api_key" }, 503);
    if (e instanceof Anthropic.RateLimitError) return json({ error: "busy" }, 429);
    if (e instanceof Anthropic.APIError) return json({ error: "api_error", detail: e.message }, 502);
    return json({ error: "error", detail: String(e) }, 500);
  }

  const stats = (await rpc("chat_record", { p_password: password, p_in: inTok * costMult, p_out: outTok * costMult })).data;
  if (!answer) return json({ error: "too_long", queries, stats }, 502);
  return json({
    answer, ids, queries, stats,
    model: sonnet ? "claude-sonnet-5-5" : MODEL,
    usage: { input_tokens: inTok, output_tokens: outTok },
  });
});
