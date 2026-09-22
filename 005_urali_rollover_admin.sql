-- 005: automatic batch rollover, self-contained maintenance, and an admin API.
-- Safe to run more than once.

-- ---------- settings ----------
insert into public.settings (key, value) values
  ('batches_visible', '1'),      -- how many upcoming batches the page shows
  ('rollover_enabled', 'true'),  -- move unfilled batches forward automatically
  ('max_rollovers', '3')         -- give up after this many moves and let a human decide
on conflict (key) do nothing;

create or replace function public.setting_text(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select value #>> '{}' from public.settings where key = p_key
$$;
revoke execute on function public.setting_text(text) from public;

-- ---------- allow the new statuses ----------
alter table public.batches drop constraint if exists batches_status_check;
alter table public.batches add constraint batches_status_check
  check (status in ('open','confirmed','full','closed','cancelled','rolled','fried','delivered'));

alter table public.reservations
  add column if not exists rollover_count int not null default 0,
  add column if not exists original_batch_id date;

update public.reservations set original_batch_id = batch_id where original_batch_id is null;

-- ---------- find the next batch a reservation can move into ----------
create or replace function public.next_open_batch(p_after date, p_boxes int default 0)
returns date
language sql stable security definer set search_path = public as $$
  select b.id from public.batches b
  where b.id > p_after
    and b.status in ('open','confirmed')
    and b.cutoff_at > now()
    and b.reserved_boxes + p_boxes <= b.capacity_boxes
  order by b.id
  limit 1
$$;
revoke execute on function public.next_open_batch(date, int) from public;

-- ---------- move one reservation to another batch ----------
create or replace function public.move_reservation(p_code text, p_to date, p_reason text default 'manual')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r public.reservations%rowtype;
  b public.batches%rowtype;
  v_after int;
begin
  select * into r from public.reservations where code = p_code for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if r.status not in ('reserved','link_sent') then
    raise exception 'CANNOT_MOVE_%', upper(r.status);
  end if;
  if p_to = r.batch_id then raise exception 'SAME_BATCH'; end if;

  select * into b from public.batches where id = p_to for update;
  if not found then raise exception 'BATCH_NOT_FOUND'; end if;
  if b.status not in ('open','confirmed') or b.cutoff_at <= now() then
    raise exception 'BATCH_CLOSED';
  end if;
  if b.reserved_boxes + r.boxes > b.capacity_boxes then
    raise exception 'BATCH_FULL:%', greatest(b.capacity_boxes - b.reserved_boxes, 0);
  end if;

  -- take the boxes off the old batch
  update public.batches set
    reserved_boxes = greatest(reserved_boxes - r.boxes, 0),
    status = case when status = 'full' then 'confirmed' else status end
  where id = r.batch_id;

  -- put them on the new one
  v_after := b.reserved_boxes + r.boxes;
  update public.batches set
    reserved_boxes = v_after,
    status = case when v_after >= capacity_boxes then 'full'
                  when v_after >= target_boxes then 'confirmed'
                  else status end,
    confirmed_at = case when confirmed_at is null and v_after >= target_boxes then now() else confirmed_at end
  where id = p_to;

  update public.reservations set
    batch_id = p_to,
    rollover_count = case when p_reason = 'rollover' then rollover_count + 1 else rollover_count end,
    status = 'reserved',
    payment_link_id = null, payment_url = null, link_sent_at = null, link_expires_at = null
  where id = r.id;

  return jsonb_build_object('code', p_code, 'from', r.batch_id, 'to', p_to,
                            'boxes', r.boxes, 'reason', p_reason);
end $$;
revoke execute on function public.move_reservation(text, date, text) from public;

-- ---------- roll unfilled batches forward ----------
create or replace function public.rollover_unfilled_batches() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.batches%rowtype;
  r record;
  v_to date;
  v_moved int := 0;
  v_stuck int := 0;
  v_batches int := 0;
  v_max int := coalesce(public.setting_int('max_rollovers'), 3);
begin
  if coalesce(public.setting_text('rollover_enabled'), 'true') <> 'true' then
    return jsonb_build_object('enabled', false);
  end if;

  for b in
    select * from public.batches
    where status = 'open' and cutoff_at <= now()
    order by id
    for update skip locked
  loop
    v_batches := v_batches + 1;
    for r in
      select code, boxes, rollover_count from public.reservations
      where batch_id = b.id and status in ('reserved','link_sent')
      order by created_at
    loop
      v_to := public.next_open_batch(b.id, r.boxes);
      if v_to is null or r.rollover_count >= v_max then
        v_stuck := v_stuck + 1;
      else
        perform public.move_reservation(r.code, v_to, 'rollover');
        v_moved := v_moved + 1;
      end if;
    end loop;

    update public.batches
    set status = case when (select count(*) from public.reservations
                            where batch_id = b.id and status in ('reserved','link_sent')) > 0
                      then 'closed' else 'rolled' end
    where id = b.id;
  end loop;

  return jsonb_build_object('batches_processed', v_batches, 'moved', v_moved, 'needs_attention', v_stuck);
end $$;
revoke execute on function public.rollover_unfilled_batches() from public;

-- ---------- one call that keeps everything tidy ----------
create or replace function public.run_maintenance() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_new int;
  v_expired int;
  v_roll jsonb;
begin
  v_new := public.ensure_batches();
  v_expired := public.expire_unpaid();
  v_roll := public.rollover_unfilled_batches();
  -- batches whose fry date has passed are done
  update public.batches set status = 'fried'
  where status in ('confirmed','full') and id < (now() at time zone 'Asia/Kolkata')::date;
  return jsonb_build_object('ran_at', now(), 'batches_created', v_new,
                            'links_expired', v_expired, 'rollover', v_roll);
end $$;
revoke execute on function public.run_maintenance() from public;

-- ---------- admin reporting ----------
drop view if exists public.admin_batches;
create view public.admin_batches as
select b.id as batch_id,
       to_char(b.id, 'Dy DD Mon') as fry_label,
       b.cutoff_at,
       b.delivery_from, b.delivery_to,
       b.reserved_boxes, b.target_boxes, b.capacity_boxes, b.status,
       greatest(b.target_boxes - b.reserved_boxes, 0) as boxes_to_target,
       (select count(*) from public.reservations r
         where r.batch_id = b.id and r.status in ('reserved','link_sent','paid')) as orders,
       (select coalesce(sum(r.total), 0) from public.reservations r
         where r.batch_id = b.id and r.status in ('reserved','link_sent','paid')) as value,
       (select coalesce(sum(r.total), 0) from public.reservations r
         where r.batch_id = b.id and r.status = 'paid') as collected
from public.batches b
order by b.id;

drop view if exists public.admin_kitchen;
create view public.admin_kitchen as
select r.batch_id,
       item ->> 'name' as product,
       sum((item ->> 'qty')::int) as boxes
from public.reservations r, jsonb_array_elements(r.items) item
where r.status in ('reserved','link_sent','paid') and r.source <> 'qa'
group by 1, 2
order by 1, 2;

drop view if exists public.admin_delivery;
create view public.admin_delivery as
select r.batch_id, r.area, r.code, r.customer_name, r.phone, r.address, r.note,
       r.boxes, r.total, r.status, r.items
from public.reservations r
where r.status in ('reserved','link_sent','paid','delivered') and r.source <> 'qa'
order by r.batch_id, r.area, r.created_at;

drop view if exists public.admin_orders;
create view public.admin_orders as
select r.code, r.created_at, r.batch_id, r.original_batch_id, r.rollover_count, r.status,
       r.customer_name, r.phone, r.area, r.address, r.note,
       r.boxes, r.items, r.subtotal, r.delivery_fee, r.total,
       r.risk_flags, host(r.ip) as ip, r.client ->> 'device' as device,
       r.utm ->> 'source' as utm_source, r.referrer
from public.reservations r
where r.source <> 'qa'
order by r.created_at desc;

drop view if exists public.admin_summary;
create view public.admin_summary as
select
  (select count(*) from public.reservations where source <> 'qa' and status in ('reserved','link_sent','paid')) as active_orders,
  (select coalesce(sum(boxes),0) from public.reservations where source <> 'qa' and status in ('reserved','link_sent','paid')) as active_boxes,
  (select coalesce(sum(total),0) from public.reservations where source <> 'qa' and status in ('reserved','link_sent','paid')) as pipeline_value,
  (select coalesce(sum(total),0) from public.reservations where source <> 'qa' and status = 'paid') as collected,
  (select count(distinct phone) from public.reservations where source <> 'qa' and status <> 'cancelled') as customers,
  (select count(distinct session_id) from public.events where created_at > now() - interval '7 days' and event = 'page_view') as visitors_7d,
  (select count(distinct session_id) from public.events where created_at > now() - interval '7 days' and event = 'reserve_success') as reserved_7d;

-- ---------- admin actions ----------
create or replace function public.admin_action(p_action text, p_code text default null,
                                               p_batch date default null, p_value text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  case p_action
    when 'cancel' then
      perform public.release_reservation(p_code, 'cancelled');
      v := jsonb_build_object('ok', true, 'action', 'cancel', 'code', p_code);
    when 'move' then
      v := public.move_reservation(p_code, p_batch, 'manual');
    when 'mark_paid' then
      update public.reservations set status = 'paid', paid_at = now()
      where code = p_code and status in ('reserved','link_sent');
      if not found then raise exception 'CANNOT_MARK_PAID'; end if;
      update public.batches b set paid_boxes = (
        select coalesce(sum(r.boxes),0) from public.reservations r
        where r.batch_id = b.id and r.status = 'paid')
      where b.id = (select batch_id from public.reservations where code = p_code);
      v := jsonb_build_object('ok', true, 'action', 'mark_paid', 'code', p_code);
    when 'mark_delivered' then
      update public.reservations set status = 'delivered' where code = p_code and status = 'paid';
      if not found then raise exception 'CANNOT_MARK_DELIVERED'; end if;
      v := jsonb_build_object('ok', true, 'action', 'mark_delivered', 'code', p_code);
    when 'batch_status' then
      if p_value not in ('open','confirmed','closed','cancelled','fried','delivered') then
        raise exception 'STATUS_INVALID';
      end if;
      update public.batches set status = p_value where id = p_batch;
      v := jsonb_build_object('ok', true, 'action', 'batch_status', 'batch', p_batch, 'status', p_value);
    when 'maintenance' then
      v := public.run_maintenance();
    when 'set_setting' then
      update public.settings set value = to_jsonb(p_value) where key = p_code;
      if not found then raise exception 'SETTING_NOT_FOUND'; end if;
      v := jsonb_build_object('ok', true, 'key', p_code, 'value', p_value);
    else
      raise exception 'UNKNOWN_ACTION';
  end case;
  return v;
end $$;

-- ---------- the admin database role (used only by the second PostgREST) ----------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'urali_admin') then
    create role urali_admin nologin;
  end if;
end $$;
grant usage on schema public to urali_admin;
grant select on public.admin_orders, public.admin_batches, public.admin_kitchen,
                public.admin_delivery, public.admin_summary, public.admin_funnel_daily,
                public.batches, public.products, public.settings to urali_admin;
grant execute on function public.admin_action(text, text, date, text) to urali_admin;
revoke execute on function public.admin_action(text, text, date, text) from public, anon, authenticated;

-- keep the public API blind to all of it
revoke all on public.admin_orders, public.admin_batches, public.admin_kitchen,
               public.admin_delivery, public.admin_summary from anon, authenticated;

notify pgrst, 'reload schema';
