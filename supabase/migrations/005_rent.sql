-- 임대 매물. 피드(source)를 'kencorp'(매매) / 'kencorp-rent'(임대)로 나눠 같은 적재 함수를 쓴다.
--   · 임대 행의 price_man 은 월 임대료(万円)다.
--   · 건물은 피드별로 한 행씩 생기며, site + bldg_code 로 같은 건물임을 잇는다.
alter table public.listings  add column deal_type text
  generated always as (case when source like '%-rent' then 'rent' else 'buy' end) stored;
alter table public.buildings add column site text
  generated always as (split_part(source, '-', 1)) stored;
create index buildings_site_code_idx on public.buildings (site, bldg_code);
create index listings_deal_idx on public.listings (deal_type);

drop view public.listings_enriched;
create view public.listings_enriched with (security_invoker = true) as
select
  l.*,
  (l.delisted_on is null)                                   as is_active,
  round(l.price_man / nullif(coalesce(l.area_tsubo, l.area_sqm / 3.305785), 0), 1)
                                                            as price_per_tsubo_man,
  b.bldg_code, b.name as bldg_name, b.kind as bldg_kind,
  b.address, b.ward_code, b.ward, b.town, b.chome, b.address_key,
  b.lat, b.lng, b.access, b.completed_ym,
  nullif(left(b.completed_ym, 4), '')::int                  as completed_year,
  b.structure, b.total_units, b.floors_above, b.floors_below, b.land_right,
  b.builder, b.developer, b.mgmt_company, b.facilities,
  count(*) filter (where l.delisted_on is null)
      over (partition by l.building_id)                     as bldg_active_listings,
  count(*) over (partition by l.building_id)                as bldg_total_listings,
  (count(*) filter (where l.delisted_on is null)
      over (partition by l.building_id)
      - (l.delisted_on is null)::int) > 0                   as has_other_listing_in_bldg,
  case when coalesce(l.room_no, '') = '' then 1 else
    count(*) over (partition by l.building_id, coalesce(l.wing, ''), l.room_no) end
                                                            as same_unit_listings,
  count(*) filter (where l.delisted_on is null)
      over (partition by l.source, b.address_key)           as address_active_listings,
  ar.area_codes, ar.area_names,
  ev.initial_price_man, ev.price_changes, ev.last_price_change_on,
  b.route_summary, b.school, b.mgmt_type,
  -- 같은 건물의 임대 매물 (매매 행에서 의미가 있다)
  rent.n                                                    as bldg_rent_listings,
  round(rent.per_sqm::numeric, 4)                           as bldg_rent_per_sqm_man,
  case when l.deal_type = 'buy' and rent.n > 0 and l.price_man > 0 then
    round((rent.per_sqm * l.area_sqm * 12 / l.price_man * 100)::numeric, 2) end
                                                            as est_gross_yield_pct
from public.listings l
join public.buildings b on b.id = l.building_id
left join lateral (
  select array_agg(a.code order by a.code) as area_codes,
         array_agg(a.name order by a.code) as area_names
  from public.buildings sb
  join public.building_areas ba on ba.building_id = sb.id
  join public.areas a on a.source = ba.source and a.code = ba.area_code
  where sb.site = b.site and sb.bldg_code = b.bldg_code
) ar on true
left join lateral (
  select
    (array_agg(e.price_man order by e.observed_on, e.id)
       filter (where e.event = 'new'))[1]                   as initial_price_man,
    count(*) filter (where e.event = 'price_change')        as price_changes,
    max(e.observed_on) filter (where e.event = 'price_change') as last_price_change_on
  from public.listing_events e where e.listing_id = l.id
) ev on true
left join lateral (
  select count(*) as n,
         percentile_cont(0.5) within group (order by rl.price_man / nullif(rl.area_sqm, 0)) as per_sqm
  from public.listings rl
  join public.buildings rb on rb.id = rl.building_id
  where rb.site = b.site and rb.bldg_code = b.bldg_code
    and rl.deal_type = 'rent' and rl.delisted_on is null and rl.area_sqm > 0
) rent on true;
