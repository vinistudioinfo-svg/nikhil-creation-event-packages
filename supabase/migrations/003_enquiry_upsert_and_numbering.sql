-- Nikhil Creation Event Packages
-- Prevent duplicate saves for the same client enquiry/session.
-- Reuse the same enquiry ID when the package is edited.
-- Client-facing enquiry/booking numbers start from 01.

create sequence if not exists public.nc_client_reference_seq;

do $$
declare
  v_max bigint;
begin
  select max(
    case
      when enquiry_number ~ '^[0-9]+$'
      then enquiry_number::bigint
      else 0
    end
  )
  into v_max
  from public.nc_enquiries;

  if v_max is null or v_max < 1 then
    perform setval('public.nc_client_reference_seq', 1, false);
  else
    perform setval('public.nc_client_reference_seq', v_max, true);
  end if;
end $$;

create unique index if not exists nc_enquiries_access_token_unique_idx
  on public.nc_enquiries(access_token_hash)
  where access_token_hash is not null;

-- Recreate enquiry save as an UPSERT by the private client access token.
create or replace function public.nc_submit_enquiry(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  p_client jsonb := coalesce(payload->'client','{}'::jsonb);
  p_functions jsonb := coalesce(payload->'functions','[]'::jsonb);
  p_package_addons jsonb := coalesce(payload->'packageAddons','[]'::jsonb);
  p_album jsonb := coalesce(payload->'album','{}'::jsonb);

  v_client_id uuid;
  v_enquiry_id uuid;
  v_function_id uuid;
  v_existing_enquiry public.nc_enquiries%rowtype;
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
  v_is_update boolean := false;
begin
  if length(coalesce(p_client->>'fullName','')) < 2
     or length(coalesce(p_client->>'mobile','')) < 10
     or length(coalesce(p_client->>'email','')) < 5 then
    raise exception using message = 'Client details are incomplete';
  end if;

  if v_access_token_hash is null or length(v_access_token_hash) < 32 then
    raise exception using message = 'Access token is missing';
  end if;

  -- Find the existing enquiry created by this client/session.
  select *
  into v_existing_enquiry
  from public.nc_enquiries
  where access_token_hash = v_access_token_hash
  limit 1;

  if found then
    v_is_update := true;
    v_enquiry_id := v_existing_enquiry.id;
    v_client_id := v_existing_enquiry.client_id;
    v_enquiry_number := v_existing_enquiry.enquiry_number;
    v_proposal_number := v_existing_enquiry.proposal_number;

    update public.nc_clients
    set
      full_name = trim(p_client->>'fullName'),
      mobile = trim(p_client->>'mobile'),
      email = lower(trim(p_client->>'email')),
      otp_verified = true,
      updated_at = now()
    where id = v_client_id;

    -- The enquiry has not yet become a booking in the normal client flow.
    -- Remove old package details so the edited package is rebuilt atomically.
    delete from public.nc_booking_items
    where function_id in (
      select id from public.nc_functions where enquiry_id = v_enquiry_id
    )
    or (
      function_id is null
      and booking_id is null
      and exists (
        select 1 from public.nc_enquiries e
        where e.id = v_enquiry_id
      )
    );

    delete from public.nc_albums
    where enquiry_id = v_enquiry_id;

    delete from public.nc_functions
    where enquiry_id = v_enquiry_id;

  else
    insert into public.nc_clients(full_name,mobile,email,otp_verified)
    values (
      trim(p_client->>'fullName'),
      trim(p_client->>'mobile'),
      lower(trim(p_client->>'email')),
      true
    )
    returning id into v_client_id;

    v_enquiry_number := lpad(nextval('public.nc_client_reference_seq')::text, 2, '0');
    v_proposal_number := 'NC' || to_char(current_date,'YYYY') || '-' ||
                        upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));

    insert into public.nc_enquiries(
      client_id,enquiry_number,status,client_total,internal_cost,profit,margin_percent,
      proposal_number,proposal_valid_till,access_token_hash
    )
    values (
      v_client_id,v_enquiry_number,'Enquiry',0,0,0,0,
      v_proposal_number,v_valid_till,v_access_token_hash
    )
    returning id into v_enquiry_id;
  end if;

  for v_func in select value from jsonb_array_elements(p_functions)
  loop
    insert into public.nc_functions(
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

    for v_item in
      select value from jsonb_array_elements(coalesce(v_func->'items','[]'::jsonb))
    loop
      v_qty := greatest(coalesce((v_item->>'quantity')::integer,0),0);
      if v_qty = 0 then continue; end if;

      select * into v_price
      from public.nc_pricing
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

      insert into public.nc_booking_items(
        booking_id,function_id,item_type,item_name,quantity,
        client_unit_price,internal_unit_cost,client_total,internal_total
      )
      values (
        null,v_function_id,v_price.item_type,v_price.item_name,v_qty,
        v_price.client_price,v_price.internal_cost,
        v_price.client_price*v_qty,v_price.internal_cost*v_qty
      );
    end loop;

    update public.nc_functions
    set function_total = coalesce((
      select sum(client_total)
      from public.nc_booking_items
      where function_id=v_function_id
    ),0)
    where id=v_function_id;
  end loop;

  for v_addon in select value from jsonb_array_elements(p_package_addons)
  loop
    v_qty := greatest(coalesce((v_addon->>'quantity')::integer,0),0);
    if v_qty = 0 then continue; end if;

    select * into v_price
    from public.nc_pricing
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

    insert into public.nc_booking_items(
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
    from public.nc_pricing
    where item_name='Premium Album' and active=true
    limit 1;

    if not found or v_price.internal_cost is null then
      raise exception using message = 'Premium Album internal cost is not configured';
    end if;

    v_sell := v_sell + 18000;
    v_cost := v_cost + v_price.internal_cost;

    if v_album_pages > 0 then
      select internal_cost into v_album_extra_cost
      from public.nc_pricing
      where item_name='Premium Album Extra Page' and active=true
      limit 1;

      if v_album_extra_cost is null then
        raise exception using message = 'Internal cost for Premium Album extra pages is not configured';
      end if;

      v_sell := v_sell + (v_album_extra_price*v_album_pages);
      v_cost := v_cost + (v_album_extra_cost*v_album_pages);
    end if;

    insert into public.nc_albums(
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

  update public.nc_enquiries
  set
    client_total=v_sell,
    internal_cost=v_cost,
    profit=v_profit,
    margin_percent=v_margin,
    status=case when status='Booking Created' then status else 'Enquiry' end,
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
    'marginPercent',v_margin,
    'updated',v_is_update
  );
end;
$$;

revoke execute on function public.nc_submit_enquiry(jsonb) from public, anon, authenticated;
grant execute on function public.nc_submit_enquiry(jsonb) to service_role;

-- Booking uses the same client-facing reference as the enquiry.
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
  e public.nc_enquiries%rowtype;
  v_booking_id uuid;
  v_booking_number text;
  v_advance numeric;
  v_balance numeric;
begin
  select * into e
  from public.nc_enquiries
  where id=p_enquiry_id
    and access_token_hash=p_access_token_hash
  for update;

  if not found then
    raise exception using message='Enquiry not found or access token invalid';
  end if;

  if exists(select 1 from public.nc_bookings where enquiry_id=e.id) then
    select id,booking_number,client_total,advance_amount,balance_amount
    into v_booking_id,v_booking_number,v_advance,v_balance
    from public.nc_bookings
    where enquiry_id=e.id
    limit 1;

    return jsonb_build_object(
      'bookingId',v_booking_id,
      'bookingNumber',v_booking_number,
      'clientTotal',e.client_total,
      'advanceAmount',v_advance,
      'balanceAmount',v_balance,
      'marginPercent',e.margin_percent,
      'existing',true
    );
  end if;

  v_advance := round(e.client_total * greatest(0,least(p_advance_percent,100)) / 100,2);
  v_balance := e.client_total - v_advance;

  v_booking_number := e.enquiry_number;

  insert into public.nc_bookings(
    enquiry_id,client_id,booking_number,status,client_total,
    advance_percent,advance_amount,balance_amount,payment_status
  )
  values (
    e.id,e.client_id,v_booking_number,'Payment Pending',e.client_total,
    p_advance_percent,v_advance,v_balance,'Pending'
  )
  returning id into v_booking_id;

  update public.nc_booking_items
  set booking_id=v_booking_id
  where function_id in (
    select id from public.nc_functions where enquiry_id=e.id
  )
  and booking_id is null;

  update public.nc_booking_items
  set booking_id=v_booking_id
  where function_id is null
    and booking_id is null
    and id in (
      select bi.id
      from public.nc_booking_items bi
      where bi.function_id is null
    );

  update public.nc_enquiries
  set status='Booking Created',updated_at=now()
  where id=e.id;

  return jsonb_build_object(
    'bookingId',v_booking_id,
    'bookingNumber',v_booking_number,
    'clientTotal',e.client_total,
    'advanceAmount',v_advance,
    'balanceAmount',v_balance,
    'marginPercent',e.margin_percent,
    'existing',false
  );
end;
$$;

revoke execute on function public.nc_create_booking(uuid,text,numeric) from public, anon, authenticated;
grant execute on function public.nc_create_booking(uuid,text,numeric) to service_role;
