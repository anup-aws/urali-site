-- urali core schema: products, batches, reservations, settings, waitlist
-- Safe to run once in the Supabase SQL editor (or via the Supabase connector).
-- All times are stored as timestamptz; batch dates are in IST (Asia/Kolkata).

-- gen_random_uuid() is built into Postgres 13+, no extension needed

-- ---------- settings ----------
create table if not exists public.settings (
  key   text primary key,
  value jsonb not null
);

insert into public.settings (key, value) values
  ('delivery_fee',        '40'),
  ('free_delivery_above', '599'),
  ('max_per_product',     '5'),
  ('max_active_per_phone_per_batch', '3'),
  ('areas', '["Kothanur","Horamavu","Ramamurthy Nagar","Byrathi"]'),
  ('target_boxes',   '40'),
  ('capacity_boxes', '60'),
  ('payment_window_hours', '24')
on conflict (key) do nothing;

-- ---------- products ----------
create table if not exists public.products (
  id         text primary key,
  name       text not null,
  name_ml    text,
  size_label text,
  price      int check (price is null or price > 0),
  status     text not null default 'soon' check (status in ('open','soon','hidden')),
  sort       int  not null default 0,
  created_at timestamptz not null default now()
);

insert into public.products (id, name, name_ml, size_label, price, status, sort) values
  ('classic', 'Kaya Varuthathu',   'കായ വറുത്തത്', '500 g of salted nendran chips', 399, 'open', 1),
  ('duo',     'Madhuram Duo',      'മധുരം', '250 g kaya varuthathu and 250 g sharkara varatti', 449, 'open', 2),
  ('tin',     'Palaharam Tin',     'പലഹാരം', 'Chips, sharkara varatti, achappam, kuzhalappam and halwa', null, 'soon', 3),
  ('chakka',  'Chakka Varuthathu', 'ചക്ക വറുത്തത്', 'Jackfruit chips, when the season comes back', null, 'soon', 4)
on conflict (id) do nothing;

-- ---------- batches (id = fry date) ----------
create table if not exists public.batches (
  id             date primary key,
  cutoff_at      timestamptz not null,
  delivery_from  date not null,
  delivery_to    date not null,
  target_boxes   int  not null default 40 check (target_boxes > 0),
  capacity_boxes int  not null default 60 check (capacity_boxes >= target_boxes),
  reserved_boxes int  not null default 0  check (reserved_boxes >= 0),
  paid_boxes     int  not null default 0  check (paid_boxes >= 0),
  status         text not null default 'open'
                 check (status in ('open','confirmed','full','closed','cancelled','fried','delivered')),
  confirmed_at   timestamptz,
  created_at     timestamptz not null default now()
);

-- ---------- reservations (personal data: never publicly readable) ----------
create table if not exists public.reservations (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique,
  batch_id        date not null references public.batches(id),
  items           jsonb not null,
  boxes           int  not null check (boxes > 0),
  subtotal        int  not null check (subtotal >= 0),
  delivery_fee    int  not null check (delivery_fee >= 0),
  total           int  not null check (total >= 0),
  customer_name   text not null,
  phone           text not null,            -- E.164, e.g. +919876543210
  area            text not null,
  address         text not null,
  note            text,
  status          text not null default 'reserved'
                  check (status in ('reserved','link_sent','paid','expired','moved','cancelled','delivered')),
  payment_link_id text,
  payment_url     text,
  link_sent_at    timestamptz,
  link_expires_at timestamptz,
  paid_at         timestamptz,
  source          text not null default 'landing',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists reservations_batch_status_idx on public.reservations (batch_id, status);
create index if not exists reservations_phone_idx on public.reservations (phone);

-- ---------- waitlist for coming-soon products ----------
create table if not exists public.waitlist (
  id         bigint generated always as identity primary key,
  product_id text not null references public.products(id),
  phone      text not null,
  created_at timestamptz not null default now(),
  unique (product_id, phone)
);

-- ---------- updated_at trigger ----------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists reservations_touch on public.reservations;
create trigger reservations_touch before update on public.reservations
for each row execute function public.touch_updated_at();

-- ---------- row level security ----------
alter table public.settings     enable row level security;
alter table public.products     enable row level security;
alter table public.batches      enable row level security;
alter table public.reservations enable row level security;
alter table public.waitlist     enable row level security;

-- Public can read products and batch counts only. No policies on reservations,
-- settings or waitlist means the public API cannot read or write them at all.
drop policy if exists "public reads visible products" on public.products;
create policy "public reads visible products" on public.products
  for select to anon, authenticated using (status in ('open','soon'));

drop policy if exists "public reads batches" on public.batches;
create policy "public reads batches" on public.batches
  for select to anon, authenticated using (true);

revoke all on public.reservations, public.settings, public.waitlist from anon, authenticated;
revoke insert, update, delete on public.products, public.batches from anon, authenticated;
grant select on public.products, public.batches to anon, authenticated;

-- ---------- helpers ----------
create or replace function public.setting_int(p_key text) returns int
language sql stable security definer set search_path = public as $$
  select (value #>> '{}')::int from public.settings where key = p_key
$$;

-- Create batch rows for the next 6 Wednesdays (orders close the Sunday before, 9 pm IST).
create or replace function public.ensure_batches() returns int
language plpgsql security definer set search_path = public as $$
declare
  today   date := (now() at time zone 'Asia/Kolkata')::date;
  next_wed date := today + ((3 - extract(isodow from today)::int + 7) % 7);
  fry     date;
  added   int := 0;
  n       int;
begin
  for i in 0..5 loop
    fry := next_wed + 7 * i;
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

-- ---------- the public entry point: reserve boxes ----------
create or replace function public.create_reservation(
  p_batch   date,
  p_items   jsonb,
  p_name    text,
  p_phone   text,
  p_area    text,
  p_address text,
  p_note    text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b          public.batches%rowtype;
  pr         public.products%rowtype;
  it         jsonb;
  q          int;
  v_phone    text;
  v_name     text := btrim(coalesce(p_name, ''));
  v_address  text := btrim(coalesce(p_address, ''));
  v_note     text := nullif(btrim(coalesce(p_note, '')), '');
  v_items    jsonb := '[]'::jsonb;
  v_boxes    int := 0;
  v_subtotal int := 0;
  v_fee      int;
  v_max      int := coalesce(public.setting_int('max_per_product'), 5);
  v_limit    int := coalesce(public.setting_int('max_active_per_phone_per_batch'), 3);
  v_active   int;
  v_code     text;
  v_after    int;
begin
  -- customer details
  if length(v_name) < 2 or length(v_name) > 80 then
    raise exception 'NAME_INVALID';
  end if;

  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(v_phone) = 12 and left(v_phone, 2) = '91' then v_phone := substr(v_phone, 3); end if;
  if length(v_phone) = 11 and left(v_phone, 1) = '0'  then v_phone := substr(v_phone, 2); end if;
  if v_phone !~ '^[6-9][0-9]{9}$' then
    raise exception 'PHONE_INVALID';
  end if;
  v_phone := '+91' || v_phone;

  if not exists (
    select 1 from public.settings s, jsonb_array_elements_text(s.value) a
    where s.key = 'areas' and a = p_area
  ) then
    raise exception 'AREA_INVALID';
  end if;

  if length(v_address) < 8 or length(v_address) > 300 then
    raise exception 'ADDRESS_INVALID';
  end if;
  if v_note is not null and length(v_note) > 300 then
    raise exception 'NOTE_TOO_LONG';
  end if;

  -- items: priced on the server, never trusted from the browser
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 10 then
    raise exception 'ITEMS_INVALID';
  end if;
  if (select count(distinct x->>'product_id') from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'ITEMS_INVALID';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    if coalesce(it->>'qty', '') !~ '^[0-9]{1,2}$' then
      raise exception 'QTY_INVALID';
    end if;
    q := (it->>'qty')::int;
    if q < 1 or q > v_max then
      raise exception 'QTY_INVALID';
    end if;
    select * into pr from public.products where id = it->>'product_id' and status = 'open';
    if not found or pr.price is null then
      raise exception 'PRODUCT_UNAVAILABLE';
    end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'product_id', pr.id, 'name', pr.name, 'qty', q, 'unit_price', pr.price, 'line', pr.price * q));
    v_boxes := v_boxes + q;
    v_subtotal := v_subtotal + pr.price * q;
  end loop;

  v_fee := case when v_subtotal >= coalesce(public.setting_int('free_delivery_above'), 599)
                then 0 else coalesce(public.setting_int('delivery_fee'), 40) end;

  -- lock the batch row so two people can't take the last boxes at once
  select * into b from public.batches where id = p_batch for update;
  if not found then
    raise exception 'BATCH_NOT_FOUND';
  end if;
  if b.status = 'full' then
    raise exception 'BATCH_FULL:0';
  end if;
  if b.status not in ('open', 'confirmed') or now() >= b.cutoff_at then
    raise exception 'BATCH_CLOSED';
  end if;
  if b.reserved_boxes + v_boxes > b.capacity_boxes then
    raise exception 'BATCH_FULL:%', greatest(b.capacity_boxes - b.reserved_boxes, 0);
  end if;

  select count(*) into v_active from public.reservations
  where batch_id = p_batch and phone = v_phone and status in ('reserved', 'link_sent', 'paid');
  if v_active >= v_limit then
    raise exception 'TOO_MANY_RESERVATIONS';
  end if;

  loop
    v_code := 'URL-' || (10000 + floor(random() * 90000))::int::text;
    exit when not exists (select 1 from public.reservations where code = v_code);
  end loop;

  insert into public.reservations
    (code, batch_id, items, boxes, subtotal, delivery_fee, total,
     customer_name, phone, area, address, note)
  values
    (v_code, p_batch, v_items, v_boxes, v_subtotal, v_fee, v_subtotal + v_fee,
     v_name, v_phone, p_area, v_address, v_note);

  v_after := b.reserved_boxes + v_boxes;
  update public.batches set
    reserved_boxes = v_after,
    status = case when v_after >= capacity_boxes then 'full'
                  when v_after >= target_boxes   then 'confirmed'
                  else status end,
    confirmed_at = case when confirmed_at is null and v_after >= target_boxes then now() else confirmed_at end
  where id = p_batch;

  return jsonb_build_object(
    'code', v_code,
    'batch', p_batch,
    'delivery_from', b.delivery_from,
    'delivery_to', b.delivery_to,
    'items', v_items,
    'boxes', v_boxes,
    'subtotal', v_subtotal,
    'delivery_fee', v_fee,
    'total', v_subtotal + v_fee,
    'was_confirmed', b.reserved_boxes >= b.target_boxes,
    'now_confirmed', v_after >= b.target_boxes,
    'reserved_boxes', v_after,
    'target_boxes', b.target_boxes
  );
end $$;

-- Release boxes when a reservation is cancelled, expires or moves. Admin/server use only.
create or replace function public.release_reservation(p_code text, p_new_status text) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.reservations%rowtype;
begin
  if p_new_status not in ('expired', 'cancelled', 'moved') then
    raise exception 'STATUS_INVALID';
  end if;
  select * into r from public.reservations where code = p_code for update;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if r.status not in ('reserved', 'link_sent') then
    raise exception 'CANNOT_RELEASE_%', upper(r.status);
  end if;
  update public.reservations set status = p_new_status where id = r.id;
  update public.batches set
    reserved_boxes = greatest(reserved_boxes - r.boxes, 0),
    status = case when status = 'full' then 'confirmed' else status end
  where id = r.batch_id;
end $$;

-- Expire unpaid payment links (runs hourly once payment links are live).
create or replace function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select code from public.reservations
    where status = 'link_sent' and link_expires_at < now()
    for update skip locked
  loop
    perform public.release_reservation(r.code, 'expired');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Close batches that didn't reach the target by cutoff.
create or replace function public.close_unfilled_batches() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.batches set status = 'closed'
  where status = 'open' and cutoff_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- function permissions ----------
revoke execute on function public.create_reservation(date, jsonb, text, text, text, text, text) from public;
revoke execute on function public.ensure_batches() from public;
revoke execute on function public.release_reservation(text, text) from public;
revoke execute on function public.expire_unpaid() from public;
revoke execute on function public.close_unfilled_batches() from public;
revoke execute on function public.setting_int(text) from public;

grant execute on function public.create_reservation(date, jsonb, text, text, text, text, text) to anon, authenticated;

-- create the first batches now
select public.ensure_batches();
