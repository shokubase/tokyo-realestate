-- 국토교통성 不動産情報ライブラリ 의 중고 맨션 실거래가.
-- 건물명·호수는 공개되지 않는다. 동네(地区)·면적(5㎡ 단위)·건축연도·분기 수준.
create table public.transactions (
  id          bigint generated always as identity primary key,
  source      text not null default 'mlit',
  city_code   text not null,          -- 13103 = 港区
  ward        text,
  town        text,                   -- 地区名 (buildings.town 과 같은 표기)
  source_kind text not null check (source_kind in ('survey', 'closed')),
                                      -- survey = 不動産取引価格情報(설문), closed = 成約価格情報(REINS)
  year        int not null,
  quarter     int not null,
  period      int generated always as (year * 10 + quarter) stored,
  price_man   numeric(12,2) not null, -- 万円
  area_sqm    numeric(9,2) not null,
  layout      text,
  built_year  int,
  structure   text,
  station     text,
  walk_min    numeric(5,1),
  renovated   text,
  purpose     text,
  note        text
);
create index transactions_city_period_idx on public.transactions (city_code, period);
create index transactions_town_idx on public.transactions (town);

alter table public.transactions enable row level security;
create policy "public read" on public.transactions for select to anon using (true);

-- 한 시구(city)의 지정 기간을 통째로 교체한다 (원본에 행 식별자가 없어서).
create function public.ingest_transactions(
  p_token text, p_source text, p_city_code text, p_from int, p_to int, p_rows jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_del int; v_ins int;
begin
  perform private.check_token(p_token);
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'empty payload';
  end if;

  delete from public.transactions
  where source = p_source and city_code = p_city_code and period between p_from and p_to;
  get diagnostics v_del = row_count;

  insert into public.transactions (
    source, city_code, ward, town, source_kind, year, quarter, price_man, area_sqm, layout,
    built_year, structure, station, walk_min, renovated, purpose, note)
  select p_source, p_city_code, r.ward, r.town, r.source_kind, r.year, r.quarter, r.price_man,
         r.area_sqm, r.layout, r.built_year, r.structure, r.station, r.walk_min, r.renovated,
         r.purpose, r.note
  from jsonb_to_recordset(p_rows) as r(
    ward text, town text, source_kind text, year int, quarter int, price_man numeric,
    area_sqm numeric, layout text, built_year int, structure text, station text,
    walk_min numeric, renovated text, purpose text, note text)
  where r.year * 10 + r.quarter between p_from and p_to;
  get diagnostics v_ins = row_count;

  return jsonb_build_object('deleted', v_del, 'inserted', v_ins);
end $$;
