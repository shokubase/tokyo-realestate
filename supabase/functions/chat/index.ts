// 채팅 검색: 한국어 질문 → 검색 조건(JSON).
// 매물 데이터는 Claude에 보내지 않는다. 조건만 돌려주고, 실제 검색은 페이지가 한다.
// 필요한 시크릿: ANTHROPIC_API_KEY  (Supabase 대시보드 → Edge Functions → Secrets)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "npm:@anthropic-ai/sdk";
import { zodOutputFormat } from "npm:@anthropic-ai/sdk/helpers/zod";
import { z } from "npm:zod";

const MODEL = "claude-haiku-5-5";
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// 페이지가 매물마다 계산해 두는 지표. extra 조건과 sort_field 에 쓸 수 있다.
const FIELDS = [
  "price", "area_sqm", "tsubo_price", "built_year", "age_years", "floor", "walk_min", "total_units",
  "yield_pct", "monthly_fee_man", "discount_vs_town_pct", "discount_vs_town_band_pct",
  "town_price_rank_pct", "price_drop_pct", "bldg_listings",
] as const;

const Query = z.object({
  understood: z.boolean().describe("매물 검색 질문으로 해석할 수 있으면 true"),
  deal: z.enum(["buy", "rent"]).describe("buy=매매, rent=임대(월세)"),
  wards: z.array(z.string()).describe("구 일본어 이름 목록 (제공된 목록의 이름만, 예: 渋谷区)"),
  areas: z.array(z.string()).describe("세부 지역 코드 목록 (제공된 목록의 code만)"),
  towns: z.array(z.string()).describe("동네(町) 일본어 이름 목록 (제공된 목록의 이름만)"),
  area_min: z.number().nullable().describe("전용면적 하한 ㎡"),
  area_max: z.number().nullable().describe("전용면적 상한 ㎡"),
  price_min: z.number().nullable().describe("가격 하한. 매매=억 엔, 임대=월 만 엔"),
  price_max: z.number().nullable().describe("가격 상한. 매매=억 엔, 임대=월 만 엔"),
  yield_min: z.number().nullable().describe("예상 표면 수익률 하한 % (매매만)"),
  yield_max: z.number().nullable().describe("예상 표면 수익률 상한 % (매매만)"),
  rooms: z.array(z.number()).describe("방 개수 (1,2,3 / 4는 4개 이상)"),
  built_after: z.number().nullable().describe("준공 연도 하한"),
  sort: z.enum([
    "new", "price_asc", "price_desc", "tsubo_asc", "tsubo_desc",
    "area_desc", "year_desc", "yield_desc", "yield_asc",
  ]),
  extra: z.array(z.object({
    field: z.enum(FIELDS),
    op: z.enum([">=", "<=", "=="]),
    value: z.number(),
  })).describe("지표로 만드는 추가 조건 (모두 만족해야 함). 없으면 빈 배열"),
  sort_field: z.enum(FIELDS).nullable().describe("지표로 정렬할 때. 지정하면 sort 보다 우선한다"),
  sort_dir: z.enum(["asc", "desc"]).nullable(),
  limit: z.number().nullable().describe("상위 N건만 원할 때"),
  reply: z.string().describe("적용한 조건을 한두 문장으로 설명 (지시된 언어로)"),
});

async function sb(path: string) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { headers: { apikey: SB_ANON, Authorization: `Bearer ${SB_ANON}` } });
  if (!r.ok) throw new Error(`supabase ${r.status}`);
  return r.json();
}

// 지역 목록은 워커가 살아 있는 동안 한 번만 읽는다
type Places = { text: string; wards: Set<string>; areas: Set<string>; towns: Set<string> };
let places: Promise<Places> | null = null;
function loadPlaces(): Promise<Places> {
  places ??= (async () => {
    const areas = await sb("areas?select=code,name&source=eq.kencorp&order=code");
    // PostgREST 는 한 번에 1,000행까지만 준다 → 끝까지 나눠 읽는다
    const blds: { town: string; ward: string }[] = [];
    for (let off = 0; ; off += 1000) {
      const page = await sb(`buildings?select=town,ward&order=id&limit=1000&offset=${off}`);
      blds.push(...page);
      if (page.length < 1000) break;
    }
    const withTown = blds.filter((b: { town: string }) => b.town);
    const labels = [...new Set(withTown.map((b: { town: string; ward: string }) => `${b.town}(${b.ward})`))];
    const wards = new Set<string>(withTown.map((b: { ward: string }) => b.ward).filter(Boolean));
    return {
      text: `구:\n${[...wards].join(", ")}\n\n세부 지역 (code = 이름):\n${areas.map((a: { code: string; name: string }) => `${a.code} = ${a.name}`).join("\n")}\n\n동네(町):\n${labels.join(", ")}`,
      wards,
      areas: new Set<string>(areas.map((a: { code: string }) => a.code)),
      towns: new Set<string>(withTown.map((b: { town: string }) => b.town)),
    };
  })().catch((e) => { places = null; throw e; });
  return places;
}

const SYSTEM = (placeText: string, lang: "ko" | "ja") => `너는 도쿄 주거용 부동산 매물 검색 페이지의 검색 조건 변환기다.
가족이 한국어나 일본어로 묻는 질문을 검색 조건으로 바꾼다. 매물 데이터는 네가 볼 수 없고, 네가 만든 조건으로 페이지가 검색한다.

## 지역
질문의 지역명(한글 발음, 일본어, 영문 모두 가능)을 아래 목록에서 찾아 넣는다.
한글로 적힌 지명은 먼저 일본어 읽기로 바꾼 뒤(히로오 = ひろお = 広尾, 에비스 = えびす = 恵比寿) 동네 목록을 처음부터 끝까지 대조한다. 목록에 있는데 없다고 답하지 않도록 한다.
- 동네(町) 단위로 특정되면 towns 에 일본어 이름만 넣는다 (괄호 안의 구 이름은 빼고). 예: "미나미아자부" → 南麻布. towns 에는 아래 동네 목록에 실제로 있는 이름만 넣을 수 있다.
- "시부야구", "미나토구"처럼 구를 말하면 wards 에 일본어 구 이름을 넣는다. "시부야"처럼 구 이름이자 동네 이름이면, "구"를 붙였을 때만 wards 로 보고 아니면 세부 지역이나 동네로 본다.
- "아자부 일대", "롯폰기 쪽"처럼 넓게 말하면 areas 에 세부 지역 code 를 넣는다.
- 말한 동네가 동네 목록에는 없지만 세부 지역 이름에 들어 있으면(예: 동네 목록에 없는 "오모테산도" → 表参道・原宿・青山) 그 세부 지역 code 를 areas 에 넣고, reply 에서 그 동네만 따로 고를 수 없어 해당 세부 지역 전체로 검색한다고 알린다.
- 동네 이름이 여러 동네의 앞부분이면(예: "아자부" → 南麻布, 元麻布, 西麻布, 東麻布, 麻布十番, 麻布台 …) 해당하는 동네를 모두 넣는다.
- 목록에 없는 지역이면 비워 두고 reply 에서 그 지역 데이터가 없다고 알린다. 지역을 말하지 않았으면 wards, areas, towns 모두 빈 배열.

${placeText}

## 단위와 해석
- 가격: 매매는 억 엔, 임대는 월 만 엔 단위 숫자. "3억 이하" → price_max 3. "월세 50만 이하" → price_max 50.
- 금액은 모두 엔이다. 원화로 말하면 환산하지 말고 숫자를 엔으로 간주하되 reply 에서 엔 기준이라고 알린다.
- 면적: ㎡. "평방미터", "제곱미터", "m2", "㎡"는 모두 ㎡이고 평이 아니다. "80㎡ 근방/정도/쯤" 또는 그냥 "80㎡" → area_min 70, area_max 90 (±10㎡). "80㎡ 이상" → area_min 80. "25평"처럼 평으로만 말했을 때만 1평 = 3.3058㎡ 로 환산한다.
- "평당 가격이 싼" → sort tsubo_asc. "비싼 순" → price_desc. 특별한 말이 없으면 sort 는 new.
- 수익률은 매매 매물의 예상 표면 수익률(같은 건물의 임대 매물 기준, %)이다. "수익률 3% 이상" → deal buy, yield_min 3, sort yield_desc. "수익률 높은" → yield_desc.
- "매물 가격 대비 월세가 싼 곳"은 매매가에 비해 월세가 낮다, 즉 수익률이 낮다는 뜻이다 → deal buy, sort yield_asc. reply 에서는 "매매가에 비해 월세가 낮은(수익률이 낮은) 순"이라고 말한다.
- 수익률 조건이나 수익률 정렬을 쓰면, 같은 건물에 임대 매물이 있는 매매 매물만 수익률 값이 있어 그 범위에서 찾는다고 reply 에서 알린다.
- "월세", "임대", "렌트"를 찾으면 deal rent. 그 외에는 buy.
- 조건에 없는 값은 null 또는 빈 배열로 둔다.

## 지표 조건 (extra, sort_field)
위의 기본 조건으로 표현할 수 없는 요구는 아래 지표를 조합해 extra 와 sort_field 로 만든다. 페이지가 매물마다 이 값을 계산해 두었다.
"조건으로 만들 수 없다"고 답하기 전에 반드시 이 지표들로 근사할 수 있는지 먼저 따져 본다. 애매한 표현은 합리적인 기준값을 스스로 정해 적용하고, reply 에서 어떤 기준으로 해석했는지 숫자와 함께 밝힌다.

- price: 가격 (매매는 억 엔, 임대는 월 만 엔). 가격 범위는 price_min/price_max 를 쓴다.
- area_sqm: 전용면적 ㎡
- tsubo_price: 평단가 (만 엔/坪)
- built_year: 준공 연도 / age_years: 건물 나이(년)
- floor: 층 / total_units: 건물 총 세대수
- walk_min: 가장 가까운 역까지 도보 분
- yield_pct: 예상 표면 수익률 % (같은 건물에 임대 매물이 있는 매매만)
- monthly_fee_man: 월 관리비+수선적립금 (만 엔)
- discount_vs_town_pct: 같은 동네 매물들의 평단가 중앙값보다 몇 % 싼지. 양수면 주변보다 싸고 음수면 비싸다.
- discount_vs_town_band_pct: 같은 동네·같은 평형대 기준으로 본 같은 값 (더 엄밀하지만 값이 없는 매물이 많다)
- town_price_rank_pct: 그 동네의 평단가 수준 순위 0~100. 100에 가까울수록 비싼(선호도 높은) 동네다.
- price_drop_pct: 처음 확인한 가격보다 몇 % 내렸는지
- bldg_listings: 같은 건물의 게재 매물 수

해석 예시 (기준값은 예시이며 질문의 강도에 맞춰 조절한다):
- "입지가 좋은" → town_price_rank_pct >= 60, 역세권을 말하면 walk_min <= 7 (또는 5)
- "낡은", "오래된", "구축" → built_year <= 1995 / "신축", "새 건물" → built_year >= 2015
- "주변(인근)보다 싼", "저평가" → discount_vs_town_pct >= 10, 그리고 sort_field discount_vs_town_pct, sort_dir desc
- "입지는 좋은데 낡아서 주변보다 싼" → 위 세 가지를 함께 건다
- "고층" → floor >= 20 / "대단지" → total_units >= 200 / "관리비가 싼" → sort_field monthly_fee_man, sort_dir asc
- "가격을 내린" → price_drop_pct >= 1
지표 값이 없는 매물은 그 조건에서 빠진다는 점도 필요하면 reply 에서 알린다. 조건을 너무 많이 걸어 결과가 0건이 될 것 같으면 핵심 조건만 남긴다.

## reply
reply 는 반드시 ${lang === "ja" ? "일본어(です・ます체)" : "한국어"}로 쓴다. 질문이 어떤 언어로 왔든 마찬가지다.
지명(구, 세부 지역, 동네)은 목록에 적힌 한자 표기 그대로 쓴다. 한글이나 가나로 음을 옮겨 적지 않는다(麻布十番 을 "마포주반" 같은 식으로 쓰지 않는다). 동네가 4개를 넘으면 앞의 3개만 적고 "외 N곳"(일본어면 "ほかNか所")으로 줄인다.
적용한 조건을 한두 문장으로 짧게 말한다. 매물을 추천하거나 투자 판단을 하지 않는다.
매물 검색이 아닌 질문이면 understood 를 false 로 하고 reply 에서 어떤 식으로 물으면 되는지 예를 하나 든다.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let body: { password?: string; question?: string; lang?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const question = (body.question ?? "").trim();
  if (!question || question.length > 500) return json({ error: "bad_request" }, 400);

  // 비밀번호 + 하루 한도 (DB에서 판정)
  const gate = await fetch(`${SB_URL}/rest/v1/rpc/chat_gate`, {
    method: "POST",
    headers: { apikey: SB_ANON, Authorization: `Bearer ${SB_ANON}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_password: body.password ?? null }),
  }).then((r) => r.json()).catch(() => "error");
  if (gate !== "ok") return json({ error: gate }, gate === "bad_password" ? 401 : 429);

  if (!Deno.env.get("ANTHROPIC_API_KEY")) return json({ error: "no_api_key" }, 503);

  try {
    const client = new Anthropic();
    const known = await loadPlaces();
    const response = await client.messages.parse({
      model: MODEL,
      max_tokens: 16000,
      // low 에서는 한글 지명 → 한자 동네 대조가 들쭉날쭉했다 (히로오 → 広尾 를 놓침)
      output_config: { effort: "medium", format: zodOutputFormat(Query) },
      system: SYSTEM(known.text, body.lang === "ja" ? "ja" : "ko"),
      messages: [{ role: "user", content: question }],
    });
    if (response.stop_reason === "refusal" || !response.parsed_output) {
      return json({ error: "no_answer" }, 502);
    }
    // 목록에 없는 지역은 버린다 (없는 동네로 걸러 결과가 0건이 되는 것을 막는다)
    const query = response.parsed_output;
    query.wards = query.wards.filter((w) => known.wards.has(w));
    query.areas = query.areas.filter((c) => known.areas.has(c));
    query.towns = query.towns.filter((t) => known.towns.has(t));
    // 사용량을 쌓고, 이번 달 집계를 함께 돌려준다 (페이지의 사용량 표시용)
    const u = response.usage;
    const stats = await fetch(`${SB_URL}/rest/v1/rpc/chat_record`, {
      method: "POST",
      headers: { apikey: SB_ANON, Authorization: `Bearer ${SB_ANON}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        p_password: body.password ?? null,
        p_in: (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0),
        p_out: u.output_tokens ?? 0,
      }),
    }).then((r) => r.json()).catch(() => null);
    return json({ query, model: response.model, usage: response.usage, stats });
  } catch (e) {
    if (e instanceof Anthropic.AuthenticationError) return json({ error: "bad_api_key" }, 503);
    if (e instanceof Anthropic.RateLimitError) return json({ error: "busy" }, 429);
    if (e instanceof Anthropic.APIError) return json({ error: "api_error", detail: e.message }, 502);
    return json({ error: "error", detail: String(e) }, 500);
  }
});
