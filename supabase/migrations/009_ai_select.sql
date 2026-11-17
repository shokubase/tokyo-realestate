-- "깊이 분석"용: AI가 읽기 전용 SQL로 DB를 직접 조회한다.
--   · ai_select 는 호출자(anon) 권한으로 실행된다 → 공개 읽기 정책이 있는 테이블만 읽을 수 있고 쓰지 못한다.
--   · 질의는 서브쿼리로 감싸 실행하므로 SELECT 가 아닌 문장은 문법 오류가 된다.
--   · anon 의 문장 제한 시간(3초)이 그대로 적용된다.

-- anon 이 부를 수 있는 비밀번호 확인 창구 (private.family_ok 는 직접 부를 수 없다)
create function public.family_check(p_password text) returns boolean
language sql security definer set search_path = '' as $$
  select private.family_ok(p_password);
$$;

-- 조회하기 쉬운 납작한 뷰. 무거운 집계 없이 매물 1행 = 1건.
create view public.ai_listings with (security_invoker = true) as
select
  l.id, l.deal_type, (l.delisted_on is null) as is_active,
  b.ward, b.town, b.chome, b.bldg_code, b.name as bldg_name,
  l.floor, l.room_no, l.layout, l.orientation,
  l.area_sqm, round(l.area_sqm / 3.305785, 2) as area_tsubo,
  l.price_man,                                                   -- 매매: 가격(万円) / 임대: 월 임대료(万円)
  round(l.price_man / nullif(l.area_sqm / 3.305785, 0), 1) as price_per_tsubo_man,
  l.admin_fee_yen, l.repair_reserve_yen,
  nullif(left(b.completed_ym, 4), '')::int as completed_year,
  b.total_units, b.floors_above, b.structure, b.land_right,
  l.occupancy, l.transaction_type,
  (substring(b.route_summary from '徒歩([0-9]+)分'))::int as walk_min,
  b.route_summary, b.lat, b.lng,
  l.is_new, l.is_price_changed, l.first_seen, l.last_seen, l.delisted_on,
  (select array_agg(distinct a.name)
     from public.buildings sb
     join public.building_areas ba on ba.building_id = sb.id
     join public.areas a on a.source = ba.source and a.code = ba.area_code
    where sb.site = b.site and sb.bldg_code = b.bldg_code) as area_names
from public.listings l
join public.buildings b on b.id = l.building_id;

create function public.ai_select(p_password text, p_sql text) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  v jsonb;
  s text := regexp_replace(btrim(coalesce(p_sql, '')), ';\s*$', '');
begin
  if not public.family_check(p_password) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if s ~ ';' then
    return jsonb_build_object('error', 'one statement only (no semicolons)');
  end if;
  if s !~* '^\s*(select|with)\M' then
    return jsonb_build_object('error', 'only SELECT queries are allowed');
  end if;
  begin
    execute format(
      'select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from (%s) q limit 200) t', s) into v;
  exception when others then
    return jsonb_build_object('error', sqlerrm);
  end;
  return jsonb_build_object('rows', v);
end $$;
