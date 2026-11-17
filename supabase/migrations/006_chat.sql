-- 채팅 검색(Edge Function `chat`)의 출입 통제: 가족 비밀번호 + 하루 호출 한도.
-- 공개 페이지에서 누구나 Claude API 크레딧을 쓰지 못하게 하기 위한 것.
create table private.chat_config (
  id          int primary key default 1 check (id = 1),
  pass_hash   text not null,           -- sha256(비밀번호)
  daily_limit int not null default 300
);
create table private.chat_usage (
  day date primary key,                -- 일본 시간 기준
  n   int not null default 0,          -- 통과한 호출 수
  bad int not null default 0           -- 비밀번호 틀린 횟수
);
alter table private.chat_config enable row level security;
alter table private.chat_usage  enable row level security;

-- 'ok' | 'bad_password' | 'limit' | 'locked' | 'not_configured'
create function public.chat_gate(p_password text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  c private.chat_config%rowtype;
  u private.chat_usage%rowtype;
  d date := (now() at time zone 'Asia/Tokyo')::date;
begin
  select * into c from private.chat_config where id = 1;
  if not found then return 'not_configured'; end if;

  insert into private.chat_usage (day) values (d) on conflict do nothing;
  select * into u from private.chat_usage where day = d for update;

  if u.bad >= 50 then return 'locked'; end if;       -- 무차별 대입 방지
  if p_password is null
     or encode(sha256(convert_to(p_password, 'UTF8')), 'hex') <> c.pass_hash then
    update private.chat_usage set bad = bad + 1 where day = d;
    return 'bad_password';
  end if;
  if u.n >= c.daily_limit then return 'limit'; end if;

  update private.chat_usage set n = n + 1 where day = d;
  return 'ok';
end $$;
