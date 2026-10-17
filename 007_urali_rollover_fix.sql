-- 007: make rollover recoverable, non-fatal, and visible
--
-- Three faults found on 2026-10-17, after the 2026-10-14 batch stranded two live
-- reservations and no later maintenance run ever retried them:
--
--   1. rollover_unfilled_batches() only walked batches with status 'open'. When a
--      batch could not be emptied it was marked 'closed' — which removed it from
--      the loop permanently. Whatever blocked the move (a full next batch, a
--      rollover cap) could clear an hour later and nothing would try again.
--
--   2. move_reservation() raises BATCH_FULL / BATCH_CLOSED. Raised inside the
--      rollover loop, that aborts the whole function, so one unmovable
--      reservation silently stops every other batch from rolling.
--
--   3. A capped reservation was counted in 'needs_attention' and then forgotten.
--      Nothing in the admin pages showed it, so a stranded order was invisible.
--
-- Idempotent. Safe to re-run.

begin;

-- ---------- 1. a workable rollover ceiling ----------
-- 3 meant an order stranded itself after ~3 weeks of unfilled batches. Early on,
-- before word of mouth builds, that is a normal amount of time to take.
insert into public.settings (key, value) values ('max_rollovers', '8')
  on conflict (key) do update set value = excluded.value;

-- ---------- 2. rollover that recovers and cannot abort itself ----------
create or replace function public.rollover_unfilled_batches() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b public.batches%rowtype;
  r record;
  v_to date;
  v_moved int := 0;
  v_capped int := 0;
  v_noroom int := 0;
  v_failed int := 0;
  v_batches int := 0;
  v_max int := coalesce(public.setting_int('max_rollovers'), 8);
begin
  if coalesce(public.setting_text('rollover_enabled'), 'true') <> 'true' then
    return jsonb_build_object('enabled', false);
  end if;

  for b in
    -- 'closed' is included so a batch that could not be emptied last time is
    -- retried once whatever blocked it has cleared. Without this, 'closed' is
    -- a terminal state and its live reservations are stranded for good.
    select * from public.batches
    where status in ('open', 'closed') and cutoff_at <= now()
    order by id
    for update skip locked
  loop
    v_batches := v_batches + 1;
    for r in
      select code, boxes, rollover_count from public.reservations
      where batch_id = b.id and status in ('reserved', 'link_sent')
      order by created_at
    loop
      if r.rollover_count >= v_max then
        v_capped := v_capped + 1;
        continue;
      end if;

      v_to := public.next_open_batch(b.id, r.boxes);
      if v_to is null then
        v_noroom := v_noroom + 1;
        continue;
      end if;

      -- A raise in here used to kill the entire run. Contain it per reservation:
      -- next_open_batch and move_reservation re-check capacity independently, so
      -- a concurrent reservation between the two can still make the move fail.
      begin
        perform public.move_reservation(r.code, v_to, 'rollover');
        v_moved := v_moved + 1;
      exception when others then
        v_failed := v_failed + 1;
      end;
    end loop;

    update public.batches
    set status = case when (select count(*) from public.reservations
                            where batch_id = b.id and status in ('reserved', 'link_sent')) > 0
                      then 'closed'   -- still has live orders; retried next run
                      else 'rolled'   -- emptied cleanly, done
                 end
    where id = b.id;
  end loop;

  return jsonb_build_object(
    'batches_processed', v_batches,
    'moved',             v_moved,
    'capped',            v_capped,
    'no_room',           v_noroom,
    'move_failed',       v_failed,
    'needs_attention',   v_capped + v_noroom + v_failed
  );
end $$;
revoke execute on function public.rollover_unfilled_batches() from public, anon, authenticated;

-- ---------- 3. make a stranded order visible ----------
drop view if exists public.admin_attention;
create view public.admin_attention as
select r.code,
       r.batch_id,
       to_char(r.batch_id, 'Dy DD Mon')                as fry_label,
       r.boxes,
       r.area,
       r.status,
       r.total,
       -- behind admin auth only, same as admin_orders: the reason text tells you
       -- to contact the customer, which needs a name and a number to be useful
       r.customer_name,
       r.phone,
       r.rollover_count,
       r.original_batch_id,
       r.created_at,
       b.status                                        as batch_status,
       b.cutoff_at,
       public.next_open_batch(r.batch_id, r.boxes)     as could_move_to,
       case
         when r.rollover_count >= coalesce(public.setting_int('max_rollovers'), 8)
           then 'rollover limit reached - contact the customer or move it by hand'
         when public.next_open_batch(r.batch_id, r.boxes) is null
           then 'no upcoming batch has room for ' || r.boxes || ' boxes'
         else 'will move on the next maintenance run'
       end                                             as reason
from public.reservations r
join public.batches b on b.id = r.batch_id
where r.status in ('reserved', 'link_sent')
  and b.cutoff_at <= now()
order by r.created_at;

grant select on public.admin_attention to urali_admin;

commit;

-- What changed, for the record
select 'max_rollovers' as setting, public.setting_int('max_rollovers') as value;
select count(*) as reservations_needing_attention from public.admin_attention;
