-- 003: spam protection, request IP / device capture, and first-party analytics events.
-- Safe to run more than once.

-- ---------- settings ----------
insert into public.settings (key, value) values
  ('min_fill_ms',                  '4000'),  -- form submitted faster than this after page load = bot
  ('max_new_per_ip_per_hour',      '6'),
  ('max_active_per_ip_per_batch',  '8'),     -- generous: mobile networks share IPs
  ('max_new_global_per_10min',     '40')     -- circuit breaker against floods
on conflict (key) do nothing;

-- ---------- reservation analytics columns ----------
alter table public.reservations
  add column if not exists ip         inet,
  add column if not exists user_agent text,
  add column if not exists referrer   text,
  add column if not exists utm        jsonb,
  add column if not exists client     jsonb,   -- session id, device, screen, language, timezone, time on page
  add column if not exists risk_flags text[] not null default '{}';

create index if not exists reservations_ip_created_idx on public.reservations (ip, created_at);
create index if not exists reservations_created_idx on public.reservations (created_at);

-- ---------- analytics events (first-party, no third-party trackers) ----------
create table if not exists public.events (
  id         bigint generated always as identity primary key,
  session_id text not null,
  event      text not null,
  props      jsonb not null default '{}',
  path       text,
  referrer   text,
  utm        jsonb,
  ip         inet,
  user_agent text,
  created_at timestamptz not null default now()
);
create index if not exists events_created_idx on public.events (created_at);
create index if not exists events_event_idx   on public.events (event, created_at);
create index if not exists events_session_idx on public.events (session_id);
create index if not exists events_ip_idx      on public.events (ip, created_at);
alter table public.events enable row level security;
revoke all on public.events from anon, authenticated;

-- ---------- request helpers (PostgREST passes HTTP headers as JSON) ----------
create or replace function public.req_header(p_name text) returns text
language sql stable as $$
  select nullif(current_setting('request.headers', true), '')::json ->> lower(p_name)
$$;

create or replace function public.req_ip() returns inet
language plpgsql stable as $$
begin
  return nullif(public.req_header('x-real-ip'), '')::inet;
exception when others then
  return null;
end $$;

-- ---------- keep the tested reservation logic as an internal function ----------
do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_reservation' and p.pronargs = 7
  ) and not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'create_reservation_core'
  ) then
    alter function public.create_reservation(date, jsonb, text, text, text, text, text)
      rename to create_reservation_core;
  end if;
end $$;
revoke execute on function public.create_reservation_core(date, jsonb, text, text, text, text, text) from public, anon, authenticated;

-- ---------- public entry point with spam checks and analytics ----------
create or replace function public.create_reservation(
  p_batch      date,
  p_items      jsonb,
  p_name       text,
  p_phone      text,
  p_area       text,
  p_address    text,
  p_note       text  default null,
  p_hp         text  default null,   -- honeypot: a hidden field real visitors never fill
  p_elapsed_ms int   default null,   -- milliseconds from page load to submit
  p_meta       jsonb default null    -- { referrer, utm:{...}, session_id, device, screen, lang, tz }
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ip    inet := public.req_ip();
  v_flags text[] := '{}';
  v_n     int;
  v_res   jsonb;
begin
  if coalesce(p_hp, '') <> '' then
    raise exception 'REQUEST_REJECTED';
  end if;

  if p_elapsed_ms is null then
    v_flags := v_flags || 'no_timing'::text;
  elsif p_elapsed_ms < coalesce(public.setting_int('min_fill_ms'), 4000) then
    raise exception 'TOO_FAST';
  end if;

  select count(*) into v_n from public.reservations
  where created_at > now() - interval '10 minutes' and source <> 'qa';
  if v_n >= coalesce(public.setting_int('max_new_global_per_10min'), 40) then
    raise exception 'BUSY';
  end if;

  if v_ip is null then
    v_flags := v_flags || 'no_ip'::text;
  else
    select count(*) into v_n from public.reservations
    where ip = v_ip and created_at > now() - interval '1 hour';
    if v_n >= coalesce(public.setting_int('max_new_per_ip_per_hour'), 6) then
      raise exception 'TOO_MANY_RESERVATIONS';
    end if;

    select count(*) into v_n from public.reservations
    where ip = v_ip and batch_id = p_batch and status in ('reserved', 'link_sent', 'paid');
    if v_n >= coalesce(public.setting_int('max_active_per_ip_per_batch'), 8) then
      raise exception 'TOO_MANY_RESERVATIONS';
    end if;
    if v_n >= 3 then
      v_flags := v_flags || 'ip_repeat'::text;
    end if;
  end if;

  v_res := public.create_reservation_core(p_batch, p_items, p_name, p_phone, p_area, p_address, p_note);

  update public.reservations set
    ip         = v_ip,
    user_agent = left(public.req_header('user-agent'), 300),
    referrer   = left(p_meta ->> 'referrer', 300),
    utm        = case when jsonb_typeof(p_meta -> 'utm') = 'object'
                       and pg_column_size(p_meta -> 'utm') < 1000 then p_meta -> 'utm' end,
    client     = case when jsonb_typeof(p_meta) = 'object'
                       and pg_column_size(p_meta) < 3000 then (p_meta - 'utm' - 'referrer') end,
    risk_flags = v_flags
  where code = v_res ->> 'code';

  return v_res;
end $$;

drop function if exists public.create_reservation(date, jsonb, text, text, text, text, text);
revoke execute on function public.create_reservation(date, jsonb, text, text, text, text, text, text, int, jsonb) from public;
grant  execute on function public.create_reservation(date, jsonb, text, text, text, text, text, text, int, jsonb) to anon, authenticated;

-- ---------- analytics event logging ----------
create or replace function public.log_event(
  p_session  text,
  p_event    text,
  p_props    jsonb default '{}',
  p_path     text  default null,
  p_referrer text  default null,
  p_utm      jsonb default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_ip inet := public.req_ip();
begin
  if p_event is null or p_event !~ '^[a-z_]{2,40}$' then return; end if;
  if p_session is null or p_session !~ '^[A-Za-z0-9-]{8,64}$' then return; end if;
  if coalesce(pg_column_size(p_props), 0) > 2000 or coalesce(pg_column_size(p_utm), 0) > 1000 then return; end if;
  if v_ip is not null and (
    select count(*) from public.events where ip = v_ip and created_at > now() - interval '10 minutes'
  ) >= 150 then
    return;
  end if;
  insert into public.events (session_id, event, props, path, referrer, utm, ip, user_agent)
  values (p_session, p_event,
          case when jsonb_typeof(p_props) = 'object' then p_props else '{}'::jsonb end,
          left(p_path, 200), left(p_referrer, 300),
          case when jsonb_typeof(p_utm) = 'object' then p_utm end,
          v_ip, left(public.req_header('user-agent'), 300));
end $$;

revoke execute on function public.log_event(text, text, jsonb, text, text, jsonb) from public;
grant  execute on function public.log_event(text, text, jsonb, text, text, jsonb) to anon, authenticated;

revoke execute on function public.req_header(text) from public;
revoke execute on function public.req_ip() from public;

-- ---------- handy views for you (not public) ----------
create or replace view public.admin_orders as
select r.code, r.created_at at time zone 'Asia/Kolkata' as created_ist, r.batch_id, r.status,
       r.customer_name, r.phone, r.area, r.boxes, r.total, r.risk_flags,
       r.ip, r.client ->> 'device' as device, r.utm ->> 'source' as utm_source, r.referrer
from public.reservations r
where r.source <> 'qa'
order by r.created_at desc;
revoke all on public.admin_orders from anon, authenticated;

create or replace view public.admin_funnel_daily as
select (created_at at time zone 'Asia/Kolkata')::date as day,
       count(distinct session_id) filter (where event = 'page_view')        as visitors,
       count(distinct session_id) filter (where event = 'box_added')        as added_box,
       count(distinct session_id) filter (where event = 'batch_selected')   as picked_batch,
       count(distinct session_id) filter (where event = 'reserve_clicked')  as clicked_reserve,
       count(distinct session_id) filter (where event = 'reserve_success')  as reserved,
       count(distinct session_id) filter (where event = 'whatsapp_clicked') as whatsapp_clicks
from public.events
group by 1
order by 1 desc;
revoke all on public.admin_funnel_daily from anon, authenticated;

-- Optional privacy retention (enable if you want): clear IPs and device strings after 90 days.
-- select cron.schedule('urali-anonymise-90d', '0 20 * * *', $$
--   update public.reservations set ip = null, user_agent = null where created_at < now() - interval '90 days';
--   update public.events set ip = null, user_agent = null where created_at < now() - interval '90 days';
-- $$);

notify pgrst, 'reload schema';
