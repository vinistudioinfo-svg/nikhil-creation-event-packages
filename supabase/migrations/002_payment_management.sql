-- Persist client payment submissions securely in Supabase.
-- Run this once in Supabase SQL Editor for project tborvfqiyehqvzludpns.

alter table public.nc_payments
  add column if not exists booking_id uuid,
  add column if not exists amount_paid numeric(12,2),
  add column if not exists utr text,
  add column if not exists status text default 'Submitted',
  add column if not exists submitted_at timestamptz default now(),
  add column if not exists verified_at timestamptz;

create index if not exists nc_payments_booking_id_idx
  on public.nc_payments(booking_id);

alter table public.nc_payments enable row level security;
revoke all on table public.nc_payments from anon, authenticated;
grant all on table public.nc_payments to service_role;

create or replace function public.nc_submit_payment(
  p_booking_id uuid,
  p_access_token_hash text,
  p_amount_paid numeric,
  p_utr text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b nc_bookings%rowtype;
  v_amount numeric;
  v_balance numeric;
  v_payment_id uuid;
begin
  select b.* into b
  from nc_bookings b
  join nc_enquiries e on e.id=b.enquiry_id
  where b.id=p_booking_id
    and e.access_token_hash=p_access_token_hash
  for update;

  if not found then
    raise exception using message='Booking not found or access token invalid';
  end if;

  v_amount := round(coalesce(p_amount_paid,0),2);

  if v_amount < 0 or v_amount > b.client_total then
    raise exception using message='Amount paid must be between 0 and the final package amount';
  end if;

  if length(trim(coalesce(p_utr,''))) < 3 then
    raise exception using message='UTR / transaction ID is required';
  end if;

  v_balance := round(b.client_total-v_amount,2);

  select id into v_payment_id
  from nc_payments
  where booking_id=b.id
  order by submitted_at desc nulls last
  limit 1;

  if v_payment_id is null then
    insert into nc_payments(
      booking_id,amount_paid,utr,status,submitted_at
    )
    values(
      b.id,v_amount,trim(p_utr),'Submitted',now()
    )
    returning id into v_payment_id;
  else
    update nc_payments
      set amount_paid=v_amount,
          utr=trim(p_utr),
          status='Submitted',
          submitted_at=now(),
          verified_at=null
    where id=v_payment_id;
  end if;

  update nc_bookings
    set payment_status='Submitted',
        advance_amount=v_amount,
        balance_amount=v_balance
  where id=b.id;

  return jsonb_build_object(
    'paymentId',v_payment_id,
    'bookingId',b.id,
    'amountPaid',v_amount,
    'remainingBalance',v_balance,
    'paymentStatus','Submitted'
  );
end;
$$;

revoke execute on function public.nc_submit_payment(uuid,text,numeric,text) from public, anon, authenticated;
grant execute on function public.nc_submit_payment(uuid,text,numeric,text) to service_role;
