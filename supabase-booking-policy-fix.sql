-- LeisureLoop booking insert policy correction
-- Run this once in Supabase SQL Editor.
drop policy if exists "Customers can create requests for approved venues" on public.bookings;
create policy "Customers can create requests for approved venues" on public.bookings
for insert to authenticated with check (
  customer_id = auth.uid()
  and status = 'pending'
  and exists (
    select 1 from public.venues v
    where v.id = venue_id and v.status = 'approved'
  )
);
