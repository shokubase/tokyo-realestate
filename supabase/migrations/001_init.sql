-- 도쿄 고급 주거용 매매 매물 추적 스키마
--   buildings       : 건물(=같은 주소지 묶음의 기준). 매물 사이트의 건물코드로 식별
--   listings        : 매물(호실). 사라져도 지우지 않고 delisted_on 만 찍는다
--   listing_events  : 변경 이력(신규/가격변경/재등록/소멸). 변화가 있을 때만 1행
--   scrape_runs     : 실행 로그
-- 쓰기는 토큰으로 보호된 RPC(ingest_*)로만. 테이블은 RLS로 잠근다.

create schema if not exists private;

create table private.ingest_tokens (
  token_hash text primary key,
  note       text,
  created_at timestamptz not null default now()
);

create function private.check_token(p_token text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_token is null or not exists (
    select 1 from private.ingest_tokens
    where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
  ) then
    raise exception 'invalid ingest token' using errcode = '28000';
  end if;
end $$;

-- ---------------------------------------------------------------- tables
create table public.scrape_runs (
  id             bigint generated always as identity primary key,
  source         text not null,
  ward_code      text not null,
  run_date       date not null,
  started_at     timestamptz not null default now(),
  bldg_count     int,
  prop_count     int,
  new_count      int,
  changed_count  int,
  relisted_count int,
  delisted_count int
);

create table public.buildings (
  id            bigint generated always as identity primary key,
  source        text not null,
  bldg_code     text not null,
  name          text not null,
  kind          text,                 -- 0=맨션, 1=단독주택, 3=토지 등 (사이트 코드)
  address       text,                 -- 東京都港区芝浦４
  ward_code     text,                 -- 사이트의 구 코드 (12=港区)
  ward          text,                 -- 港区
  town          text,                 -- 芝浦
  chome         int,                  -- 4
  address_key   text,                 -- 港区芝浦4  (丁目 단위 주소 키)
  lat           double precision,
  lng           double precision,
  route_summary text,
  completed_ym  text,                 -- YYYYMM
  -- 상세 페이지에서 채움
  access        text,
  structure     text,
  total_units   int,
  floors_above  int,
  floors_below  int,
  land_right    text,
  builder       text,
  developer     text,
  mgmt_company  text,
  mgmt_type     text,
  school        text,
  facilities    text[],
  url           text,
  first_seen    date not null,
  last_seen     date not null,
  unique (source, bldg_code)
);
create index buildings_ward_idx on public.buildings (ward_code);
create index buildings_address_key_idx on public.buildings (address_key);

create table public.listings (
  id                bigint generated always as identity primary key,
  source            text not null,
  prop_code         text not null,
  building_id       bigint not null references public.buildings (id),
  wing              text,             -- EAST / B棟 등
  room_no           text,
  floor             int,
  layout            text,
  area_sqm          numeric(9,2),
  area_tsubo        numeric(9,2),
  price_man         numeric(12,2),    -- 万円
  admin_fee_yen     int,
  yield_pct         numeric(6,2),
  usage             text,
  is_new            boolean not null default false,   -- 사이트 "신착" 배지
  is_price_changed  boolean not null default false,   -- 사이트 "가격개정" 배지
  labels            jsonb,
  icons             jsonb,
  pending           text,
  url               text,
  layout_image      text,
  images            jsonb,
  -- 상세 페이지에서 채움
  repair_reserve_yen int,
  other_fee         text,
  orientation       text,
  balcony           text,
  occupancy         text,             -- 現況
  handover          text,             -- 引渡時期
  transaction_type  text,             -- 取引形態
  parking           text,
  features          text[],
  equipment         text[],
  remarks           text,
  info_updated_on   date,
  next_update_on    date,
  spec_raw          jsonb,            -- 상세 표 원문 전체
  detail_fetched_at timestamptz,
  first_seen        date not null,
  last_seen         date not null,
  delisted_on       date,             -- null = 현재 게재 중
  unique (source, prop_code)
);
create index listings_building_idx on public.listings (building_id);
create index listings_active_idx on public.listings (delisted_on) where delisted_on is null;

create table public.listing_events (
  id             bigint generated always as identity primary key,
  listing_id     bigint not null references public.listings (id),
  run_id         bigint references public.scrape_runs (id),
  observed_on    date not null,
  event          text not null check (event in
                   ('new','price_change','change','relisted','delisted','detail_change')),
  price_man      numeric(12,2),       -- 그 시점의 가격
  prev_price_man numeric(12,2),
  changes        jsonb                -- {"필드": {"old":..,"new":..}}
);
create index listing_events_listing_idx on public.listing_events (listing_id, observed_on);
create index listing_events_event_idx on public.listing_events (event, observed_on);

-- 사이트의 세부 에리어 (구보다 세밀하고, 구 경계를 넘기도 하며, 서로 겹친다)
create table public.areas (
  source     text not null,
  code       text not null,           -- roppongi03
  name       text not null,           -- 麻布・広尾
  group_name text,                    -- 港区・都心エリアなど
  primary key (source, code)
);

create table public.building_areas (
  building_id bigint not null references public.buildings (id),
  source      text not null,
  area_code   text not null,
  primary key (building_id, area_code),
  foreign key (source, area_code) references public.areas (source, code)
);
create index building_areas_area_idx on public.building_areas (area_code);

alter table public.areas          enable row level security;
alter table public.building_areas enable row level security;
alter table private.ingest_tokens enable row level security;
alter table public.scrape_runs    enable row level security;
alter table public.buildings      enable row level security;
alter table public.listings       enable row level security;
alter table public.listing_events enable row level security;

-- ---------------------------------------------------------------- view
-- 조회·필터용. "같은 건물/같은 주소지에 다른 매물이 있는가"를 컬럼으로 제공.
create view public.listings_enriched with (security_invoker = true) as
select
  l.*,
  (l.delisted_on is null)                                   as is_active,
  round(l.price_man / nullif(l.area_tsubo, 0), 1)           as price_per_tsubo_man,
  b.bldg_code, b.name as bldg_name, b.kind as bldg_kind,
  b.address, b.ward_code, b.ward, b.town, b.chome, b.address_key,
  b.lat, b.lng, b.access, b.completed_ym,
  nullif(left(b.completed_ym, 4), '')::int                  as completed_year,
  b.structure, b.total_units, b.floors_above, b.floors_below, b.land_right,
  b.builder, b.developer, b.mgmt_company, b.facilities,
  -- 같은 건물
  count(*) filter (where l.delisted_on is null)
      over (partition by l.building_id)                     as bldg_active_listings,
  count(*) over (partition by l.building_id)                as bldg_total_listings,
  (count(*) filter (where l.delisted_on is null)
      over (partition by l.building_id)
      - (l.delisted_on is null)::int) > 0                   as has_other_listing_in_bldg,
  -- 같은 호실이 다른 매물번호로 올라온 적이 있는가 (재등록·중복 게재)
  case when coalesce(l.room_no, '') = '' then 1 else
    count(*) over (partition by l.building_id, coalesce(l.wing, ''), l.room_no) end
                                                            as same_unit_listings,
  -- 같은 丁目 주소(다른 건물 포함)
  count(*) filter (where l.delisted_on is null)
      over (partition by b.address_key)                     as address_active_listings,
  -- 사이트의 세부 에리어(麻布・広尾 등). 한 건물이 여러 에리어에 속할 수 있다
  ar.area_codes, ar.area_names,
  ev.initial_price_man, ev.price_changes, ev.last_price_change_on
from public.listings l
join public.buildings b on b.id = l.building_id
left join lateral (
  select array_agg(a.code order by a.code) as area_codes,
         array_agg(a.name order by a.code) as area_names
  from public.building_areas ba join public.areas a
    on a.source = ba.source and a.code = ba.area_code
  where ba.building_id = b.id
) ar on true
left join lateral (
  select
    (array_agg(e.price_man order by e.observed_on, e.id)
       filter (where e.event = 'new'))[1]                   as initial_price_man,
    count(*) filter (where e.event = 'price_change')        as price_changes,
    max(e.observed_on) filter (where e.event = 'price_change') as last_price_change_on
  from public.listing_events e where e.listing_id = l.id
) ev on true;
