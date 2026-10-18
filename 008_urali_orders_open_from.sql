-- 008: don't open batches before a date you choose
--
-- Deleting an early batch by hand does not work: ensure_batches() recreates the
-- next six Wednesdays on every maintenance run, so a deleted batch is back
-- within ten minutes. The start of the calendar has to be a setting the
-- function honours.
--
--   orders_open_from = the earliest fry date customers may reserve.
--   Change it any time with:
--     update public.settings set value = '"2026-12-02"' where key = 'orders_open_from';
--     select public.ensure_batches();
--
-- Idempotent. Safe to re-run.

begin;

-- Set to the first Wednesday on or after the date you want to start.
-- 2026-11-04 = "nothing before 3 November", which is what was asked for.
insert into public.settings (key, value) values ('orders_open_from', '"2026-11-04"')
  on conflict (key) do update set value = excluded.value;

create or replace function public.setting_date(p_key text) returns date
language sql stable security definer set search_path = public as $$
  select nullif(value #>> '{}', '')::date from public.settings where key = p_key
$$;
revoke execute on function public.setting_date(text) from public, anon, authenticated;

-- ---------- the calendar now starts at orders_open_from ----------
create or replace function public.ensure_batches() returns int
language plpgsql security definer set search_path = public as $$
declare
  today     date := (now() at time zone 'Asia/Kolkata')::date;
  open_from date := coalesce(public.setting_date('orders_open_from'), today);
  -- never create a batch in the past, even if orders_open_from is left behind
  start_day date := greatest(today, open_from);
  -- the first Wednesday on or after start_day (isodow 3 = Wednesday)
  first_wed date := start_day + ((3 - extract(isodow from start_day)::int + 7) % 7);
  fry       date;
  added     int := 0;
  n         int;
begin
  for i in 0..5 loop
    fry := first_wed + 7 * i;
    insert into public.batches (id, cutoff_at, delivery_from, delivery_to, target_boxes, capacity_boxes)
    values (
      fry,
      ((fry - 3)::timestamp + time '21:00') at time zone 'Asia/Kolkata',
      fry + 1,
      fry + 2,
      coalesce(public.setting_int('target_boxes'), 40),
      coalesce(public.setting_int('capacity_boxes'), 60)
    )
    on conflict (id) do nothing;
    get diagnostics n = row_count;
    added := added + n;
  end loop;
  return added;
end $$;
revoke execute on function public.ensure_batches() from public, anon, authenticated;

-- ---------- retire batches earlier than the open date ----------
-- 'cancelled' is not in the status list the landing page asks for
-- (open, confirmed, full), so these simply stop being offered. The rows stay,
-- which also stops ensure_batches recreating them.
--
-- A batch holding a live or paid order is deliberately left alone: silently
-- cancelling someone's order to tidy a calendar is not a trade worth making.
-- Anything skipped shows up in admin_attention.
update public.batches b
set status = 'cancelled'
where b.id < coalesce(public.setting_date('orders_open_from'), b.id)
  and b.status in ('open', 'confirmed', 'full')
  and not exists (
    select 1 from public.reservations r
    where r.batch_id = b.id
      and r.status in ('reserved', 'link_sent', 'paid')
  );

commit;

-- top the calendar back up to six batches from the new start
select public.ensure_batches() as batches_created;

select 'orders_open_from' as setting, public.setting_date('orders_open_from') as value;

-- any early batch left standing because it still holds a real order
select b.id as kept_early_batch, b.status, b.reserved_boxes,
       (select count(*) from public.reservations r
        where r.batch_id = b.id and r.status in ('reserved','link_sent','paid')) as live_orders
from public.batches b
where b.id < public.setting_date('orders_open_from')
  and b.status in ('open','confirmed','full');
