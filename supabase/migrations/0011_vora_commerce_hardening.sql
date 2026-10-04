-- VORA 2.4 commerce hardening: order states, checkout and inventory reservation lifecycle

do $$
begin
  alter table public.vora_orders drop constraint if exists vora_orders_status_check;
  alter table public.vora_orders add constraint vora_orders_status_check
    check(status in('pending','paid','processing','shipped','completed','cancelled','refunded'));
exception when duplicate_object then null;
end $$;

create or replace function public.vora_release_order_reservation(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare r record; n integer:=0;
begin
  for r in
    select * from public.vora_inventory_reservations
    where order_id=p_order_id and status='reserved'
    for update
  loop
    update public.vora_product_stocks
      set quantity=quantity+r.quantity, updated_at=now()
      where business_id=r.business_id
        and product_id=r.product_id
        and outlet_code=r.outlet_code;
    update public.vora_inventory_reservations
      set status='released',updated_at=now()
      where id=r.id;
    n:=n+1;
  end loop;
  return n;
end $$;

create or replace function public.vora_create_order_from_cart(
  p_business_id uuid,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 c record; ci record; st record; p record; oid uuid;
 v_subtotal numeric:=0; v_order_no text; v_existing uuid;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then
    raise exception 'invalid idempotency key';
  end if;

  select id into v_existing
  from public.vora_orders
  where business_id=p_business_id and idempotency_key=p_idempotency_key;
  if v_existing is not null then return v_existing; end if;

  select * into c
  from public.vora_carts
  where business_id=p_business_id and user_id=auth.uid() and status='active'
  for update;
  if not found then raise exception 'active cart not found'; end if;

  if not public.vora_is_member(p_business_id) then raise exception 'not authorized'; end if;

  if not exists(select 1 from public.vora_cart_items where cart_id=c.id) then
    raise exception 'cart is empty';
  end if;

  for ci in select * from public.vora_cart_items where cart_id=c.id loop
    select * into p from public.vora_products
      where id=ci.product_id and business_id=p_business_id and active=true;
    if not found then raise exception 'product unavailable: %',ci.product_id; end if;

    select * into st from public.vora_product_stocks
      where business_id=p_business_id and product_id=ci.product_id and outlet_code='MAIN'
      for update;
    if not found or st.quantity<ci.quantity then
      raise exception 'insufficient stock for product %',p.name;
    end if;
    v_subtotal:=v_subtotal+(p.sell_price*ci.quantity);
  end loop;

  v_order_no:='VORA-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));

  insert into public.vora_orders(
    business_id,order_no,customer_user_id,status,subtotal,total,idempotency_key
  ) values(
    p_business_id,v_order_no,auth.uid(),'pending',v_subtotal,v_subtotal,p_idempotency_key
  ) returning id into oid;

  for ci in select * from public.vora_cart_items where cart_id=c.id loop
    select * into p from public.vora_products where id=ci.product_id and business_id=p_business_id;
    insert into public.vora_order_items(order_id,product_id,quantity,unit_price,discount,line_total)
      values(oid,ci.product_id,ci.quantity,p.sell_price,0,p.sell_price*ci.quantity);

    update public.vora_product_stocks
      set quantity=quantity-ci.quantity,updated_at=now()
      where business_id=p_business_id and product_id=ci.product_id and outlet_code='MAIN';

    insert into public.vora_inventory_reservations(
      business_id,order_id,product_id,outlet_code,quantity,status,expires_at
    ) values(
      p_business_id,oid,ci.product_id,'MAIN',ci.quantity,'reserved',now()+interval '30 minutes'
    );
  end loop;

  update public.vora_carts set status='converted',updated_at=now() where id=c.id;

  insert into public.vora_audit_logs(
    business_id,actor_user_id,action,entity,entity_id,after_data
  ) values(
    p_business_id,auth.uid(),'order.created','vora_orders',oid,
    jsonb_build_object('subtotal',v_subtotal,'reservation_minutes',30)
  );

  return oid;
end $$;

create or replace function public.vora_release_expired_reservations(p_limit integer default 100)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare r record; n integer:=0;
begin
  for r in
    select order_id
    from public.vora_inventory_reservations
    where status='reserved' and expires_at is not null and expires_at<now()
    order by expires_at
    limit greatest(1,least(coalesce(p_limit,100),1000))
  loop
    n:=n+public.vora_release_order_reservation(r.order_id);
    update public.vora_orders
      set status='cancelled'
      where id=r.order_id and status='pending';
  end loop;
  return n;
end $$;

revoke all on function public.vora_release_order_reservation(uuid) from public;
revoke all on function public.vora_create_order_from_cart(uuid,text) from public;
revoke all on function public.vora_release_expired_reservations(integer) from public;
grant execute on function public.vora_release_order_reservation(uuid) to authenticated;
grant execute on function public.vora_create_order_from_cart(uuid,text) to authenticated;
grant execute on function public.vora_release_expired_reservations(integer) to authenticated;

create index if not exists idx_vora_order_status_created
  on public.vora_orders(business_id,status,created_at desc);
