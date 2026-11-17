-- 웹 페이지(공개)용 읽기 권한. 쓰기는 여전히 토큰 RPC로만 가능하다.
create policy "public read" on public.buildings      for select to anon using (true);
create policy "public read" on public.listings       for select to anon using (true);
create policy "public read" on public.listing_events for select to anon using (true);
create policy "public read" on public.areas          for select to anon using (true);
create policy "public read" on public.building_areas for select to anon using (true);
create policy "public read" on public.scrape_runs    for select to anon using (true);

-- 뷰에 노선 요약 추가 (상세 수집 전에도 채워져 있는 값). 컬럼은 끝에만 추가할 수 있다.
create or replace view public.listings_enriched with (security_invoker = true) as
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
      over (partition by b.address_key)                     as address_active_listings,
  ar.area_codes, ar.area_names,
  ev.initial_price_man, ev.price_changes, ev.last_price_change_on,
  b.route_summary, b.school, b.mgmt_type
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
