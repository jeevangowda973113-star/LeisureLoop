-- LeisureLoop: run this once in Supabase Dashboard > SQL Editor.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  account_type text not null default 'buyer' check (account_type in ('buyer', 'owner')),
  owner_status text not null default 'not_applicable' check (owner_status in ('not_applicable', 'pending', 'approved', 'rejected')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create or replace function public.handle_new_leisureloop_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare chosen_type text;
begin
  chosen_type := coalesce(new.raw_user_meta_data ->> 'account_type', 'buyer');
  if chosen_type not in ('buyer', 'owner') then chosen_type := 'buyer'; end if;
  insert into public.profiles (id, full_name, account_type, owner_status)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''), chosen_type,
    case when chosen_type = 'owner' then 'pending' else 'not_applicable' end);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_leisureloop on auth.users;
create trigger on_auth_user_created_leisureloop after insert on auth.users
for each row execute procedure public.handle_new_leisureloop_user();

drop policy if exists "Users can read their own profile" on public.profiles;
create policy "Users can read their own profile" on public.profiles
for select to authenticated using (auth.uid() = id);

revoke update on public.profiles from authenticated;
grant update (full_name) on public.profiles to authenticated;
drop policy if exists "Users can update their own name" on public.profiles;
create policy "Users can update their own name" on public.profiles
for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
grant select on public.profiles to authenticated;
