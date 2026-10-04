-- Nikhil Creation Event Packages
-- Secure backend foundation for enquiries/bookings.
-- Run this once in Supabase SQL Editor for project:
-- tborvfqiyehqvzludpns

create extension if not exists pgcrypto;

-- Pricing is server-only data. The browser must never read internal costs.
create table if not exists public.nc_pricing (
  id uuid primary key default gen_random_uuid(),
  item_type text not null,
  item_name text not null unique,
  client_price numeric(12,2) not null,
  internal_cost numeric(12,2),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.nc_pricing (item_type,item_name,client_price,internal_cost) values
('service','Candid Photographer',12000,7000),
('service','Traditional Photographer',7000,4000),
('service','Additional Photographer',7000,4000),
('service','Cinematic Videographer',15000,12000),
('service','Traditional Video',7000,5500),
('service','Additional Videographer',7000,5500),
('service','Drone Coverage',10000,5000),
('service','Same Day Edit',5000,2000),
('service','Live Streaming',10000,9000),
('service','Family Portrait Photo Booth',10000,2500),
('function_addon','Extra Hours',1000,1000),
('function_addon','Extra Photographer',7000,5000),
('function_addon','Extra Videographer',7000,5500),
('function_addon','Reels Pack',2000,1000),
('function_addon','Same Day Edit',5000,2000),
('function_addon','Professional Female Photographer',10000,6000),
('package_addon','Premium Album',18000,10500),
('package_addon','Highlight Film',15000,9000),
('package_addon','Teaser Film',8000,3000),
('package_addon','LED Wall / Live Screening',12000,10000)
on conflict (item_name) do update set
  item_type=excluded.item_type,
  client_price=excluded.client_price,
  internal_cost=excluded.internal_cost,
  active=true,
  updated_at=now();

-- Token hash lets a client continue an enquiry/booking without exposing internal data.
alter table public.nc_enquiries
  add column if not exists access_token_hash text;

create index if not exists nc_enquiries_access_token_hash_idx
  on public.nc_enquiries(access_token_hash);

-- Secure every application table. Client-side access will go through Edge Functions.
alter table public.nc_clients enable row level security;
alter table public.nc_enquiries enable row level security;
alter table public.nc_functions enable row level security;
alter table public.nc_booking_items enable row level security;
alter table public.nc_bookings enable row level security;
alter table public.nc_payments enable row level security;
alter table public.nc_albums enable row level security;
alter table public.nc_pricing enable row level security;

revoke all on table public.nc_clients from anon, authenticated;
revoke all on table public.nc_enquiries from anon, authenticated;
revoke all on table public.nc_functions from anon, authenticated;
revoke all on table public.nc_booking_items from anon, authenticated;
revoke all on table public.nc_bookings from anon, authenticated;
revoke all on table public.nc_payments from anon, authenticated;
revoke all on table public.nc_albums from anon, authenticated;
revoke all on table public.nc_pricing from anon, authenticated;

grant all on table public.nc_clients to service_role;
grant all on table public.nc_enquiries to service_role;
grant all on table public.nc_functions to service_role;
grant all on table public.nc_booking_items to service_role;
grant all on table public.nc_bookings to service_role;
grant all on table public.nc_payments to service_role;
grant all on table public.nc_albums to service_role;
grant all on table public.nc_pricing to service_role;

-- Default privileges: new tables/functions in public should not silently become client-accessible.
alter default privileges in schema public
  revoke select, insert, update, delete on tables from anon, authenticated;
alter default privileges in schema public
  revoke execute on functions from public, anon, authenticated;

-- Atomic server-side enquiry creation.
create or replace function public.nc_submit_enquiry(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  p_client jsonb := coalesce(payload->'client','{}'::jsonb);
  p_functions jsonb := coalesce(payload->'functions','[]'::jsonb);
  p_items jsonb := coalesce(payload->'items','[]'::jsonb);
  p_package_addons jsonb := coalesce(payload->'packageAddons','[]'::jsonb);
  p_album jsonb := coalesce(payload->'album','{}'::jsonb);

  v_client_id uuid;
  v_enquiry_id uuid;
  v_function_id uuid;
  v_item jsonb;
  v_func jsonb;
  v_addon jsonb;
  v_price record;
  v_qty integer;
  v_sell numeric := 0;
  v_cost numeric := 0;
  v_profit numeric := 0;
  v_margin numeric := 0;
  v_enquiry_number text;
  v_proposal_number text;
  v_valid_till date := current_date + 15;
  v_access_token_hash text := payload->>'accessTokenHash';
  v_album_selected boolean := coalesce((p_album->>'selected')::boolean,false);
  v_album_pages integer := greatest(coalesce((p_album->>'extraPages')::integer,0),0);
  v_album_extra_price numeric := 600;
  v_album_extra_cost numeric;
begin
  if length(coalesce(p_client->>'fullName','')) < 2
     or length(coalesce(p_client->>'mobile','')) < 10
     or length(coalesce(p_client->>'email','')) < 5 then
    raise exception using message = 'Client details are incomplete';
  end if;

  if v_access_token_hash is null or length(v_access_token_hash) < 32 then
    raise exception using message = 'Access token is missing';
  end if;

  insert into nc_clients(full_name,mobile,email,otp_verified)
  values (
    trim(p_client->>'fullName'),
    trim(p_client->>'mobile'),
    lower(trim(p_client->>'email')),
    true
  )
  returning id into v_client_id;

  v_enquiry_number := 'ENQ-' || to_char(current_date,'YYYYMMDD') || '-' ||
                      upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  v_proposal_number := 'NC' || to_char(current_date,'YYYY') || '-' ||
                       upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));

  insert into nc_enquiries(
    client_id,enquiry_number,status,client_total,internal_cost,profit,margin_percent,
    proposal_number,proposal_valid_till,access_token_hash
  )
  values (
    v_client_id,v_enquiry_number,'Enquiry',0,0,0,0,
    v_proposal_number,v_valid_till,v_access_token_hash
  )
  returning id into v_enquiry_id;

  for v_func in select value from jsonb_array_elements(p_functions)
  loop
    insert into nc_functions(
      enquiry_id,function_type,custom_function_name,event_date,start_time,end_time,
      side,venue,google_maps_url,full_address,guest_count,special_requirements,function_total
    )
    values (
      v_enquiry_id,
      coalesce(v_func->>'functionType','Custom Function'),
      nullif(trim(v_func->>'customFunctionName'),''),
      nullif(v_func->>'eventDate','')::date,
      nullif(v_func->>'startTime','')::time,
      nullif(v_func->>'endTime','')::time,
      nullif(v_func->>'side',''),
      nullif(trim(v_func->>'venue'),''),
      nullif(trim(v_func->>'googleMapsUrl'),''),
      nullif(trim(v_func->>'fullAddress'),''),
      nullif(v_func->>'guestCount','')::integer,
      nullif(trim(v_func->>'specialRequirements'),''),
      0
    )
    returning id into v_function_id;

    -- Each function's selected services/add-ons are sent with functionId.
    for v_item in
      select value from jsonb_array_elements(
        coalesce(v_func->'items','[]'::jsonb)
      )
    loop
      v_qty := greatest(coalesce((v_item->>'quantity')::integer,0),0);
      if v_qty = 0 then continue; end if;

      select * into v_price
      from nc_pricing
      where item_name = v_item->>'itemName' and active = true
      limit 1;

      if not found then
        raise exception using message = 'Unknown pricing item: ' || coalesce(v_item->>'itemName','');
      end if;

      if v_price.internal_cost is null then
        raise exception using message = 'Internal cost is not configured for: ' || v_price.item_name;
      end if;

      v_sell := v_sell + (v_price.client_price * v_qty);
      v_cost := v_cost + (v_price.internal_cost * v_qty);

      insert into nc_booking_items(
        booking_id,function_id,item_type,item_name,quantity,
        client_unit_price,internal_unit_cost,client_total,internal_total
      )
      values (
        null,v_function_id,v_price.item_type,v_price.item_name,v_qty,
        v_price.client_price,v_price.internal_cost,
        v_price.client_price*v_qty,v_price.internal_cost*v_qty
      );
    end loop;

    update nc_functions
      set function_total = coalesce((
        select sum(client_total)
        from nc_booking_items
        where function_id=v_function_id
      ),0)
    where id=v_function_id;
  end loop;

  for v_addon in select value from jsonb_array_elements(p_package_addons)
  loop
    v_qty := greatest(coalesce((v_addon->>'quantity')::integer,0),0);
    if v_qty = 0 then continue; end if;

    select * into v_price
    from nc_pricing
    where item_name = v_addon->>'itemName'
      and item_type='package_addon'
      and active=true
    limit 1;

    if not found then
      raise exception using message = 'Unknown package add-on: ' || coalesce(v_addon->>'itemName','');
    end if;

    if v_price.internal_cost is null then
      raise exception using message = 'Internal cost is not configured for: ' || v_price.item_name;
    end if;

    v_sell := v_sell + (v_price.client_price * v_qty);
    v_cost := v_cost + (v_price.internal_cost * v_qty);

    insert into nc_booking_items(
      booking_id,function_id,item_type,item_name,quantity,
      client_unit_price,internal_unit_cost,client_total,internal_total
    )
    values (
      null,null,v_price.item_type,v_price.item_name,v_qty,
      v_price.client_price,v_price.internal_cost,
      v_price.client_price*v_qty,v_price.internal_cost*v_qty
    );
  end loop;

  if v_album_selected then
    select internal_cost into v_price
    from nc_pricing
    where item_name='Premium Album' and active=true;

    if not found or v_price.internal_cost is null then
      raise exception using message = 'Premium Album internal cost is not configured';
    end if;

    v_sell := v_sell + 18000;
    v_cost := v_cost + v_price.internal_cost;

    if v_album_pages > 0 then
      -- Extra-page internal cost is intentionally not guessed.
      select internal_cost into v_album_extra_cost
      from nc_pricing
      where item_name='Premium Album Extra Page' and active=true;
      if v_album_extra_cost is null then
        raise exception using message = 'Internal cost for Premium Album extra pages is not configured';
      end if;
      v_sell := v_sell + (v_album_extra_price*v_album_pages);
      v_cost := v_cost + (v_album_extra_cost*v_album_pages);
    end if;

    insert into nc_albums(
      enquiry_id,selected,base_client_price,base_internal_cost,
      extra_pages,extra_page_price,client_total,internal_total
    )
    values (
      v_enquiry_id,true,18000,v_price.internal_cost,
      v_album_pages,v_album_extra_price,
      18000+(v_album_extra_price*v_album_pages),
      v_price.internal_cost+(coalesce(v_album_extra_cost,0)*v_album_pages)
    );
  end if;

  if v_sell <= 0 then
    raise exception using message = 'No priced items were selected';
  end if;

  v_profit := v_sell - v_cost;
  v_margin := round((v_profit / v_sell) * 100,2);

  update nc_enquiries
    set client_total=v_sell,
        internal_cost=v_cost,
        profit=v_profit,
        margin_percent=v_margin,
        updated_at=now()
  where id=v_enquiry_id;

  return jsonb_build_object(
    'enquiryId',v_enquiry_id,
    'clientId',v_client_id,
    'enquiryNumber',v_enquiry_number,
    'proposalNumber',v_proposal_number,
    'proposalValidTill',v_valid_till,
    'clientTotal',v_sell,
    'internalCost',v_cost,
    'profit',v_profit,
    'marginPercent',v_margin
  );
end;
$$;

revoke execute on function public.nc_submit_enquiry(jsonb) from public, anon, authenticated;
grant execute on function public.nc_submit_enquiry(jsonb) to service_role;

-- Atomic booking creation. Only the server-side Edge Function may call it.
create or replace function public.nc_create_booking(
  p_enquiry_id uuid,
  p_access_token_hash text,
  p_advance_percent numeric default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e nc_enquiries%rowtype;
  v_booking_id uuid;
  v_booking_number text;
  v_advance numeric;
  v_balance numeric;
begin
  select * into e
  from nc_enquiries
  where id=p_enquiry_id
    and access_token_hash=p_access_token_hash
  for update;

  if not found then
    raise exception using message='Enquiry not found or access token invalid';
  end if;

  if coalesce(e.margin_percent,0) < 60 then
    raise exception using message='Booking blocked: package margin is below the required 60%';
  end if;

  if exists(select 1 from nc_bookings where enquiry_id=e.id) then
    select id,booking_number,client_total,advance_amount,balance_amount
      into v_booking_id,v_booking_number,v_advance,v_balance
    from nc_bookings where enquiry_id=e.id limit 1;

    return jsonb_build_object(
      'bookingId',v_booking_id,
      'bookingNumber',v_booking_number,
      'clientTotal',e.client_total,
      'advanceAmount',v_advance,
      'balanceAmount',v_balance,
      'existing',true
    );
  end if;

  v_advance := round(e.client_total * greatest(0,least(p_advance_percent,100)) / 100,2);
  v_balance := e.client_total - v_advance;
  v_booking_number := 'BK-' || to_char(current_date,'YYYYMMDD') || '-' ||
                      upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));

  insert into nc_bookings(
    enquiry_id,client_id,booking_number,status,client_total,
    advance_percent,advance_amount,balance_amount,payment_status
  )
  values (
    e.id,e.client_id,v_booking_number,'Payment Pending',e.client_total,
    p_advance_percent,v_advance,v_balance,'Pending'
  )
  returning id into v_booking_id;

  update nc_booking_items
    set booking_id=v_booking_id
  where function_id in (
    select id from nc_functions where enquiry_id=e.id
  )
  and booking_id is null;

  update nc_booking_items
    set booking_id=v_booking_id
  where function_id is null
    and booking_id is null
    and id in (
      select bi.id
      from nc_booking_items bi
      left join nc_functions f on f.id=bi.function_id
      where bi.function_id is null
    );

  update nc_enquiries
    set status='Booking Created',updated_at=now()
  where id=e.id;

  return jsonb_build_object(
    'bookingId',v_booking_id,
    'bookingNumber',v_booking_number,
    'clientTotal',e.client_total,
    'advanceAmount',v_advance,
    'balanceAmount',v_balance,
    'existing',false
  );
end;
$$;

revoke execute on function public.nc_create_booking(uuid,text,numeric) from public, anon, authenticated;
grant execute on function public.nc_create_booking(uuid,text,numeric) to service_role;
