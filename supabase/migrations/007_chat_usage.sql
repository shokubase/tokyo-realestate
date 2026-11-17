-- AI 검색 사용량(토큰)을 날짜별로 쌓고, 이번 달 사용 금액을 추정해 보여준다.
-- Anthropic 에는 "남은 크레딧"을 알려주는 일반 API가 없어, 이 챗봇이 쓴 만큼만 직접 센다.
alter table private.chat_usage
  add column input_tokens  bigint not null default 0,
  add column output_tokens bigint not null default 0;

alter table private.chat_config
  add column monthly_credit_usd numeric not null default 100,   -- 플랜에 포함된 월 크레딧 (가정값)
  add column price_in_per_mtok  numeric not null default 0.10,  -- Claude Haiku 5.5 입력 $/100만 토큰
  add column price_out_per_mtok numeric not null default 0.50;  -- 출력

-- 이번 달(일본 시간) 집계. 숫자뿐이라 누구나 읽을 수 있게 둔다.
create function public.chat_stats() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'month', to_char((now() at time zone 'Asia/Tokyo'), 'YYYY-MM'),
    'calls', coalesce(sum(u.n), 0),
    'input_tokens', coalesce(sum(u.input_tokens), 0),
    'output_tokens', coalesce(sum(u.output_tokens), 0),
    'cost_usd', round(coalesce(sum(u.input_tokens * c.price_in_per_mtok
                                 + u.output_tokens * c.price_out_per_mtok), 0) / 1000000, 4),
    'credit_usd', max(c.monthly_credit_usd))
  from private.chat_config c
  left join private.chat_usage u
    on u.day >= date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date
  where c.id = 1;
$$;

-- 함수가 응답을 받은 뒤 토큰 수를 기록한다 (비밀번호가 맞을 때만).
create function public.chat_record(p_password text, p_in int, p_out int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if not exists (select 1 from private.chat_config
                 where id = 1 and pass_hash = encode(sha256(convert_to(coalesce(p_password, ''), 'UTF8')), 'hex')) then
    return null;
  end if;
  insert into private.chat_usage (day, input_tokens, output_tokens)
  values (d, greatest(p_in, 0), greatest(p_out, 0))
  on conflict (day) do update
    set input_tokens = private.chat_usage.input_tokens + excluded.input_tokens,
        output_tokens = private.chat_usage.output_tokens + excluded.output_tokens;
  return public.chat_stats();
end $$;
