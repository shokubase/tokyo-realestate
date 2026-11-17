-- 적재 RPC. 스크래퍼는 publishable key + ingest token 으로 이 함수들만 호출한다.

-- 한 구(ward)의 "현재 게재 중인 전체 목록"을 받아 증분 반영한다.
--   신규        → listings insert + event 'new'
--   값 변경     → listings update + event 'price_change' / 'change'
--   다시 나타남 → delisted_on 해제 + event 'relisted'
--   안 보임     → delisted_on 기록 + event 'delisted'
-- 반환: 집계 + 상세 페이지를 (다시) 받아야 하는 매물 목록
create function public.ingest_listings(
  p_token text, p_source text, p_ward_code text, p_run_date date, p_buildings jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_run_id bigint;
  v_new int := 0; v_changed int := 0; v_relisted int := 0; v_delisted int := 0;
  v_active int; v_incoming int; v_bldgs int;
  b jsonb; u jsonb; v_bid bigint; v_lid bigint;
  o public.listings%rowtype;
  v_changes jsonb; v_price numeric; v_labels jsonb;
begin
  perform private.check_token(p_token);

  select count(*), count(distinct bb->>'bldg_code') into v_incoming, v_bldgs
  from jsonb_array_elements(p_buildings) bb, jsonb_array_elements(bb->'units') uu;

  select count(*) into v_active
  from public.listings l join public.buildings bd on bd.id = l.building_id
  where l.source = p_source and bd.ward_code = p_ward_code and l.delisted_on is null;

  -- 불완전한 스크랩으로 대량 "소멸" 처리되는 사고 방지
  if v_incoming = 0 or v_incoming < v_active * 0.5 then
    raise exception 'payload too small: % incoming vs % active', v_incoming, v_active;
  end if;

  insert into public.scrape_runs (source, ward_code, run_date, bldg_count, prop_count)
  values (p_source, p_ward_code, p_run_date, v_bldgs, v_incoming)
  returning id into v_run_id;

  for b in select * from jsonb_array_elements(p_buildings) loop
    insert into public.buildings as t (
      source, bldg_code, name, kind, address, ward_code, ward, town, chome, address_key,
      lat, lng, route_summary, completed_ym, url, first_seen, last_seen)
    values (
      p_source, b->>'bldg_code', b->>'name', b->>'kind', b->>'address', p_ward_code,
      b->>'ward', b->>'town', (b->>'chome')::int, b->>'address_key',
      (b->>'lat')::float8, (b->>'lng')::float8, b->>'route_summary', b->>'completed_ym',
      b->>'url', p_run_date, p_run_date)
    on conflict (source, bldg_code) do update set
      name = excluded.name, kind = excluded.kind, address = excluded.address,
      ward_code = excluded.ward_code, ward = excluded.ward, town = excluded.town,
      chome = excluded.chome, address_key = excluded.address_key,
      lat = excluded.lat, lng = excluded.lng, route_summary = excluded.route_summary,
      completed_ym = excluded.completed_ym, url = excluded.url,
      last_seen = greatest(t.last_seen, excluded.last_seen)
    returning id into v_bid;

    for u in select * from jsonb_array_elements(b->'units') loop
      v_price  := (u->>'price_man')::numeric;
      v_labels := coalesce(u->'labels', '[]'::jsonb);

      select * into o from public.listings
      where source = p_source and prop_code = u->>'prop_code';

      if not found then
        insert into public.listings (
          source, prop_code, building_id, wing, room_no, floor, layout, area_sqm, area_tsubo,
          price_man, admin_fee_yen, yield_pct, usage, is_new, is_price_changed, labels, icons,
          pending, url, layout_image, images, first_seen, last_seen)
        values (
          p_source, u->>'prop_code', v_bid, u->>'wing', u->>'room_no', (u->>'floor')::int,
          u->>'layout', (u->>'area_sqm')::numeric, (u->>'area_tsubo')::numeric,
          v_price, (u->>'admin_fee_yen')::int, (u->>'yield_pct')::numeric, u->>'usage',
          v_labels @> '[1]', v_labels @> '[2]', v_labels, u->'icons',
          u->>'pending', u->>'url', u->>'layout_image', u->'images', p_run_date, p_run_date)
        returning id into v_lid;

        insert into public.listing_events (listing_id, run_id, observed_on, event, price_man)
        values (v_lid, v_run_id, p_run_date, 'new', v_price);
        v_new := v_new + 1;
      else
        v_changes := '{}'::jsonb;
        if o.price_man is distinct from v_price then
          v_changes := v_changes || jsonb_build_object('price_man',
            jsonb_build_object('old', o.price_man, 'new', v_price)); end if;
        if o.admin_fee_yen is distinct from (u->>'admin_fee_yen')::int then
          v_changes := v_changes || jsonb_build_object('admin_fee_yen',
            jsonb_build_object('old', o.admin_fee_yen, 'new', (u->>'admin_fee_yen')::int)); end if;
        if o.area_sqm is distinct from (u->>'area_sqm')::numeric then
          v_changes := v_changes || jsonb_build_object('area_sqm',
            jsonb_build_object('old', o.area_sqm, 'new', (u->>'area_sqm')::numeric)); end if;
        if o.layout is distinct from u->>'layout' then
          v_changes := v_changes || jsonb_build_object('layout',
            jsonb_build_object('old', o.layout, 'new', u->>'layout')); end if;
        if o.floor is distinct from (u->>'floor')::int then
          v_changes := v_changes || jsonb_build_object('floor',
            jsonb_build_object('old', o.floor, 'new', (u->>'floor')::int)); end if;
        if o.room_no is distinct from u->>'room_no' then
          v_changes := v_changes || jsonb_build_object('room_no',
            jsonb_build_object('old', o.room_no, 'new', u->>'room_no')); end if;
        if o.pending is distinct from u->>'pending' then
          v_changes := v_changes || jsonb_build_object('pending',
            jsonb_build_object('old', o.pending, 'new', u->>'pending')); end if;

        if o.delisted_on is not null then
          insert into public.listing_events
            (listing_id, run_id, observed_on, event, price_man, prev_price_man, changes)
          values (o.id, v_run_id, p_run_date, 'relisted', v_price, o.price_man,
                  jsonb_build_object('delisted_on', o.delisted_on));
          v_relisted := v_relisted + 1;
        end if;

        if v_changes <> '{}'::jsonb then
          insert into public.listing_events
            (listing_id, run_id, observed_on, event, price_man, prev_price_man, changes)
          values (o.id, v_run_id, p_run_date,
                  case when v_changes ? 'price_man' then 'price_change' else 'change' end,
                  v_price, o.price_man, v_changes);
          v_changed := v_changed + 1;
        end if;

        update public.listings set
          building_id = v_bid, wing = u->>'wing', room_no = u->>'room_no',
          floor = (u->>'floor')::int, layout = u->>'layout',
          area_sqm = (u->>'area_sqm')::numeric, area_tsubo = (u->>'area_tsubo')::numeric,
          price_man = v_price, admin_fee_yen = (u->>'admin_fee_yen')::int,
          yield_pct = (u->>'yield_pct')::numeric, usage = u->>'usage',
          is_new = v_labels @> '[1]', is_price_changed = v_labels @> '[2]',
          labels = v_labels, icons = u->'icons', pending = u->>'pending',
          url = u->>'url', layout_image = u->>'layout_image', images = u->'images',
          last_seen = greatest(last_seen, p_run_date), delisted_on = null,
          -- 값이 바뀌었거나 재등록이면 상세를 다시 받게 한다
          detail_fetched_at = case when v_changes <> '{}'::jsonb or o.delisted_on is not null
                                   then null else detail_fetched_at end
        where id = o.id;
      end if;
    end loop;
  end loop;

  with gone as (
    update public.listings l set delisted_on = p_run_date
    from public.buildings bd
    where bd.id = l.building_id and l.source = p_source and bd.ward_code = p_ward_code
      and l.delisted_on is null and l.last_seen < p_run_date
    returning l.id, l.price_man
  ), ins as (
    insert into public.listing_events (listing_id, run_id, observed_on, event, price_man)
    select id, v_run_id, p_run_date, 'delisted', price_man from gone returning 1
  )
  select count(*) into v_delisted from ins;

  update public.scrape_runs set new_count = v_new, changed_count = v_changed,
    relisted_count = v_relisted, delisted_count = v_delisted
  where id = v_run_id;

  return jsonb_build_object(
    'run_id', v_run_id, 'incoming', v_incoming, 'new', v_new, 'changed', v_changed,
    'relisted', v_relisted, 'delisted', v_delisted,
    'need_detail', coalesce((
      select jsonb_agg(jsonb_build_object('prop_code', x.prop_code, 'url', x.url))
      from (
        select l.prop_code, l.url
        from public.listings l join public.buildings bd on bd.id = l.building_id
        where l.source = p_source and bd.ward_code = p_ward_code and l.delisted_on is null
          and (l.detail_fetched_at is null or l.detail_fetched_at < now() - interval '30 days')
        order by l.detail_fetched_at nulls first, l.id
      ) x), '[]'::jsonb));
end $$;

-- 상세 페이지 결과 반영. 주요 상태값이 바뀌면 'detail_change' 이벤트를 남긴다.
create function public.ingest_details(p_token text, p_source text, p_details jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d jsonb; l jsonb; bd jsonb; o public.listings%rowtype; v_changes jsonb; n int := 0;
begin
  perform private.check_token(p_token);

  for d in select * from jsonb_array_elements(p_details) loop
    l := d->'listing'; bd := d->'building';
    select * into o from public.listings
    where source = p_source and prop_code = d->>'prop_code';
    if not found then continue; end if;

    if o.detail_fetched_at is not null or o.spec_raw is not null then
      v_changes := '{}'::jsonb;
      if o.occupancy is distinct from l->>'occupancy' then
        v_changes := v_changes || jsonb_build_object('occupancy',
          jsonb_build_object('old', o.occupancy, 'new', l->>'occupancy')); end if;
      if o.handover is distinct from l->>'handover' then
        v_changes := v_changes || jsonb_build_object('handover',
          jsonb_build_object('old', o.handover, 'new', l->>'handover')); end if;
      if o.transaction_type is distinct from l->>'transaction_type' then
        v_changes := v_changes || jsonb_build_object('transaction_type',
          jsonb_build_object('old', o.transaction_type, 'new', l->>'transaction_type')); end if;
      if o.repair_reserve_yen is distinct from (l->>'repair_reserve_yen')::int then
        v_changes := v_changes || jsonb_build_object('repair_reserve_yen',
          jsonb_build_object('old', o.repair_reserve_yen,
                             'new', (l->>'repair_reserve_yen')::int)); end if;
      if v_changes <> '{}'::jsonb then
        insert into public.listing_events (listing_id, observed_on, event, price_man, changes)
        values (o.id, current_date, 'detail_change', o.price_man, v_changes);
      end if;
    end if;

    update public.listings set
      repair_reserve_yen = (l->>'repair_reserve_yen')::int,
      other_fee = l->>'other_fee', orientation = l->>'orientation', balcony = l->>'balcony',
      occupancy = l->>'occupancy', handover = l->>'handover',
      transaction_type = l->>'transaction_type', parking = l->>'parking',
      features  = (select array_agg(x) from jsonb_array_elements_text(l->'features') x),
      equipment = (select array_agg(x) from jsonb_array_elements_text(l->'equipment') x),
      remarks = l->>'remarks',
      info_updated_on = (l->>'info_updated_on')::date,
      next_update_on  = (l->>'next_update_on')::date,
      spec_raw = d->'spec_raw', detail_fetched_at = now()
    where id = o.id;

    update public.buildings set
      access = coalesce(bd->>'access', access),
      structure = coalesce(bd->>'structure', structure),
      total_units = coalesce((bd->>'total_units')::int, total_units),
      floors_above = coalesce((bd->>'floors_above')::int, floors_above),
      floors_below = coalesce((bd->>'floors_below')::int, floors_below),
      land_right = coalesce(bd->>'land_right', land_right),
      builder = coalesce(bd->>'builder', builder),
      developer = coalesce(bd->>'developer', developer),
      mgmt_company = coalesce(bd->>'mgmt_company', mgmt_company),
      mgmt_type = coalesce(bd->>'mgmt_type', mgmt_type),
      school = coalesce(bd->>'school', school),
      facilities = coalesce(
        (select array_agg(x) from jsonb_array_elements_text(bd->'facilities') x), facilities)
    where id = o.building_id;
    n := n + 1;
  end loop;
  return jsonb_build_object('updated', n);
end $$;

-- 에리어 ↔ 건물 소속 반영. [{code,name,group_name,bldg_codes:[..]}]
-- DB에 없는 건물은 무시한다(대상 구 밖). 소속은 지리 정보라 누적만 한다.
create function public.ingest_areas(p_token text, p_source text, p_areas jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a jsonb; n int := 0; k int;
begin
  perform private.check_token(p_token);
  for a in select * from jsonb_array_elements(p_areas) loop
    insert into public.areas (source, code, name, group_name)
    values (p_source, a->>'code', a->>'name', a->>'group_name')
    on conflict (source, code) do update
      set name = excluded.name, group_name = excluded.group_name;

    insert into public.building_areas (building_id, source, area_code)
    select bd.id, p_source, a->>'code'
    from jsonb_array_elements_text(a->'bldg_codes') c
    join public.buildings bd on bd.source = p_source and bd.bldg_code = c
    on conflict do nothing;
    get diagnostics k = row_count;
    n := n + k;
  end loop;
  return jsonb_build_object('links_added', n);
end $$;
