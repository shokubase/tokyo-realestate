-- 찜하기. 가족이 공유하고, 누가 찜했는지 이름과 함께 남긴다.
-- 페이지가 공개라서 이름이 드러나지 않도록 읽기·쓰기 모두 가족 비밀번호를 거친다.
create table private.favorites (
  listing_id bigint not null references public.listings (id),
  who        text not null,                 -- 기기에서 한 번 입력한 이름(별명)
  created_at timestamptz not null default now(),
  primary key (listing_id, who)
);
alter table private.favorites enable row level security;

-- 비밀번호 확인 (틀리면 그날의 오류 횟수를 올리고, 50회를 넘으면 잠근다)
create function private.family_ok(p_password text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date; v_bad int;
begin
  insert into private.chat_usage (day) values (d) on conflict do nothing;
  select bad into v_bad from private.chat_usage where day = d;
  if v_bad >= 50 then return false; end if;
  if exists (select 1 from private.chat_config where id = 1
             and pass_hash = encode(sha256(convert_to(coalesce(p_password, ''), 'UTF8')), 'hex')) then
    return true;
  end if;
  update private.chat_usage set bad = bad + 1 where day = d;
  return false;
end $$;

-- 전체 찜 목록. 비밀번호가 틀리면 null.
create function public.fav_list(p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.family_ok(p_password) then return null; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
            'listing_id', f.listing_id, 'who', f.who, 'at', f.created_at) order by f.created_at)
          from private.favorites f), '[]'::jsonb);
end $$;

-- 찜 켜기/끄기. 바뀐 뒤의 전체 목록을 돌려준다.
create function public.fav_toggle(p_password text, p_who text, p_listing_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_who text := left(btrim(coalesce(p_who, '')), 20);
begin
  if not private.family_ok(p_password) then return null; end if;
  if v_who = '' then raise exception 'name required'; end if;
  delete from private.favorites where listing_id = p_listing_id and who = v_who;
  if not found then
    insert into private.favorites (listing_id, who) values (p_listing_id, v_who);
  end if;
  return public.fav_list(p_password);
end $$;
