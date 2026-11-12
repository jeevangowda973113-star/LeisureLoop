-- LeisureLoop secure owner + venue approval workflow.
-- Run this file in Supabase SQL Editor after the existing setup scripts.
-- After creating your own LeisureLoop account, add its email to the admin list
-- using the one-time bootstrap statement at the bottom of this file.

create table if not exists public.leisureloop_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.leisureloop_admins enable row level security;
revoke all on public.leisureloop_admins from anon, authenticated;

create or replace function public.is_leisureloop_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.leisureloop_admins a
    where a.user_id = auth.uid()
  );
$$;
revoke all on function public.is_leisureloop_admin() from public;
grant execute on function public.is_leisureloop_admin() to authenticated;

create or replace function public.admin_list_pending_owners()
returns table(user_id uuid, full_name text, email text, created_at timestamptz, owner_status text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_leisureloop_admin() then
    raise exception 'Administrator access required.';
  end if;
  return query
    select p.id, p.full_name, u.email::text, p.created_at, p.owner_status
    from public.profiles p
    join auth.users u on u.id = p.id
    where p.account_type = 'owner' and p.owner_status in ('pending','rejected')
    order by p.created_at asc;
end;
$$;

create or replace function public.admin_review_owner(p_user_id uuid, p_decision text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_leisureloop_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Invalid owner review decision.';
  end if;
  update public.profiles
  set owner_status = p_decision
  where id = p_user_id and account_type = 'owner';
  if not found then
    raise exception 'Owner account not found.';
  end if;
end;
$$;

create or replace function public.admin_list_pending_venues()
returns table(venue_id uuid, owner_id uuid, owner_name text, title text, category text,
  description text, address text, city text, hourly_rate numeric, status text, created_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_leisureloop_admin() then
    raise exception 'Administrator access required.';
  end if;
  return query
    select v.id, v.owner_id, p.full_name, v.title, v.category, v.description,
      v.address, v.city, v.hourly_rate, v.status, v.created_at
    from public.venues v
    left join public.profiles p on p.id = v.owner_id
    where v.status in ('pending','rejected')
    order by v.created_at asc;
end;
$$;

create or replace function public.admin_review_venue(p_venue_id uuid, p_decision text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_leisureloop_admin() then
    raise exception 'Administrator access required.';
  end if;
  if p_decision not in ('approved','rejected') then
    raise exception 'Invalid venue review decision.';
  end if;
  update public.venues
  set status = p_decision, updated_at = now()
  where id = p_venue_id and status in ('pending','rejected');
  if not found then
    raise exception 'Pending venue not found.';
  end if;
end;
$$;

revoke all on function public.admin_list_pending_owners() from public;
revoke all on function public.admin_review_owner(uuid,text) from public;
revoke all on function public.admin_list_pending_venues() from public;
revoke all on function public.admin_review_venue(uuid,text) from public;
grant execute on function public.admin_list_pending_owners() to authenticated;
grant execute on function public.admin_review_owner(uuid,text) to authenticated;
grant execute on function public.admin_list_pending_venues() to authenticated;
grant execute on function public.admin_review_venue(uuid,text) to authenticated;

-- ONE-TIME ADMIN BOOTSTRAP:
-- Replace the email below with the email address of your own registered account,
-- then run this separately in Supabase SQL Editor.
-- insert into public.leisureloop_admins(user_id)
-- select id from auth.users where lower(email) = lower('YOUR-LOGIN-EMAIL')
-- on conflict (user_id) do nothing;
