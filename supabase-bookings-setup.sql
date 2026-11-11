-- LeisureLoop booking + in-app notification foundation
-- Run in Supabase Dashboard > SQL Editor after supabase-setup.sql.
-- This creates real booking records and owner approval. Email delivery is a separate server-side setup.

create extension if not exists pgcrypto;

create table if not exists public.venues (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 3 and 120),
  category text not null default 'Other',
  description text not null default '',
  address text not null,
  city text not null,
  hourly_rate numeric(10,2) not null check (hourly_rate >= 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete restrict,
  owner_id uuid not null references public.profiles(id) on delete restrict,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  booking_date date not null,
  start_time time not null,
  duration_hours integer not null check (duration_hours between 1 and 24),
  group_size integer not null default 1 check (group_size between 1 and 100),
  customer_name text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete cascade,
  notification_type text not null,
  title text not null,
  message text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists venues_owner_id_idx on public.venues(owner_id);
create index if not exists venues_status_city_idx on public.venues(status, city);
create index if not exists bookings_owner_status_idx on public.bookings(owner_id, status, created_at desc);
create index if not exists bookings_customer_idx on public.bookings(customer_id, created_at desc);
create index if not exists notifications_recipient_idx on public.notifications(recipient_id, created_at desc);

alter table public.venues enable row level security;
alter table public.bookings enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "Anyone can view approved venues" on public.venues;
create policy "Anyone can view approved venues" on public.venues
for select to anon, authenticated using (status = 'approved');

drop policy if exists "Owners can view their own venues" on public.venues;
create policy "Owners can view their own venues" on public.venues
for select to authenticated using (owner_id = auth.uid());

drop policy if exists "Approved owners can submit venues" on public.venues;
drop policy if exists "Owners can submit venues for review" on public.venues;
create policy "Owners can submit venues for review" on public.venues
for insert to authenticated with check (
  owner_id = auth.uid()
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.account_type = 'owner'
      and p.owner_status in ('pending', 'approved')
  )
);

drop policy if exists "Owners can update their pending venues" on public.venues;
create policy "Owners can update their pending venues" on public.venues
for update to authenticated using (owner_id = auth.uid())
with check (owner_id = auth.uid() and status in ('pending','inactive'));

drop policy if exists "Customers can create requests for approved venues" on public.bookings;
create policy "Customers can create requests for approved venues" on public.bookings
for insert to authenticated with check (
  customer_id = auth.uid()
  and status = 'pending'
  and exists (select 1 from public.venues v where v.id = venue_id and v.status = 'approved')
);

drop policy if exists "Customers and venue owners can read relevant bookings" on public.bookings;
create policy "Customers and venue owners can read relevant bookings" on public.bookings
for select to authenticated using (customer_id = auth.uid() or owner_id = auth.uid());

drop policy if exists "Users can read their own notifications" on public.notifications;
create policy "Users can read their own notifications" on public.notifications
for select to authenticated using (recipient_id = auth.uid());

drop policy if exists "Users can mark their own notifications read" on public.notifications;
create policy "Users can mark their own notifications read" on public.notifications
for update to authenticated using (recipient_id = auth.uid())
with check (recipient_id = auth.uid());

grant select on public.venues to anon, authenticated;
grant insert, update on public.venues to authenticated;
grant select, insert on public.bookings to authenticated;
grant select, update on public.notifications to authenticated;

-- Set owner_id from the venue record; clients cannot choose another owner.
create or replace function public.set_leisureloop_booking_owner()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  select v.owner_id into new.owner_id
  from public.venues v
  where v.id = new.venue_id and v.status = 'approved';
  if new.owner_id is null then
    raise exception 'This space is not available for booking requests.';
  end if;
  if new.customer_id <> auth.uid() then
    raise exception 'You can only request a booking for your own account.';
  end if;
  new.status := 'pending';
  return new;
end;
$$;

drop trigger if exists set_leisureloop_booking_owner on public.bookings;
create trigger set_leisureloop_booking_owner
before insert on public.bookings
for each row execute function public.set_leisureloop_booking_owner();

-- Owner-only approval. Creates the customer's in-app notification in the same transaction.
create or replace function public.approve_leisureloop_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
  booking_start timestamp;
  booking_end timestamp;
begin
  select * into b from public.bookings
  where id = p_booking_id and owner_id = auth.uid() and status = 'pending'
  for update;

  if not found then
    raise exception 'Booking not found or you are not allowed to approve it.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(b.venue_id::text || ':' || b.booking_date::text, 0));

  booking_start := b.booking_date + b.start_time;
  booking_end := booking_start + make_interval(hours => b.duration_hours);

  if exists (
    select 1 from public.bookings other
    where other.venue_id = b.venue_id
      and other.id <> b.id
      and other.status = 'approved'
      and tsrange(other.booking_date + other.start_time,
                  other.booking_date + other.start_time + make_interval(hours => other.duration_hours), '[)')
          && tsrange(booking_start, booking_end, '[)')
  ) then
    raise exception 'This time overlaps an already approved booking.';
  end if;

  update public.bookings
  set status = 'approved', updated_at = now()
  where id = b.id
  returning * into b;

  insert into public.notifications(recipient_id, booking_id, notification_type, title, message)
  values (
    b.customer_id,
    b.id,
    'booking_approved',
    'Your booking is confirmed',
    'Your booking request has been approved. Open LeisureLoop to view the venue and booking details.'
  );

  return b;
end;
$$;

-- Owner-only rejection. Also notifies the customer in-app.
create or replace function public.reject_leisureloop_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.bookings;
begin
  update public.bookings
  set status = 'rejected', updated_at = now()
  where id = p_booking_id
    and owner_id = auth.uid()
    and status = 'pending'
  returning * into b;

  if not found then
    raise exception 'Booking not found or you are not allowed to reject it.';
  end if;

  insert into public.notifications(recipient_id, booking_id, notification_type, title, message)
  values (b.customer_id, b.id, 'booking_rejected', 'Booking request update',
          'The venue owner could not approve this booking request.');

  return b;
end;
$$;

revoke all on function public.approve_leisureloop_booking(uuid) from public;
revoke all on function public.reject_leisureloop_booking(uuid) from public;
grant execute on function public.approve_leisureloop_booking(uuid) to authenticated;
grant execute on function public.reject_leisureloop_booking(uuid) to authenticated;

-- Enable Supabase Realtime for in-app notification listeners.
do $$
begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null;
when undefined_object then null;
end $$;
