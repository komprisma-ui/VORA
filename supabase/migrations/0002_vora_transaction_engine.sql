create or replace function public.vora_create_order(p_business_id uuid,p_seller_member_id uuid,p_idempotency_key text,p_items jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 r record; q record; s record; v_order uuid; v_no text;
 v_sub numeric(18,2):=0; v_qual numeric(18,2):=0; v_pv numeric(18,2):=0; v_cv numeric(18,2):=0; v_qty numeric; v_line numeric(18,2);
begin
 if auth.uid() is null then raise exception 'authentication required'; end if;
 if not public.vora_is_member(p_business_id) then raise exception 'not authorized'; end if;
 select id into v_order from public.vora_orders where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if v_order is not null then return v_order; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'items required'; end if;
 if p_seller_member_id is null then
   select id into p_seller_member_id from public.vora_members where business_id=p_business_id and user_id=auth.uid() and status='active' limit 1;
 end if;
 if p_seller_member_id is null then raise exception 'seller member required'; end if;
 if not exists(select 1 from public.vora_members where id=p_seller_member_id and business_id=p_business_id and status='active') then raise exception 'invalid seller'; end if;

 for r in select * from jsonb_array_elements(p_items) loop
   v_qty:=coalesce((r.value->>'quantity')::numeric,0);
   if v_qty<=0 then raise exception 'invalid quantity'; end if;
   select p.* into s from public.vora_products p where p.id=(r.value->>'product_id')::uuid and p.business_id=p_business_id and p.active for update;
   if not found then raise exception 'product unavailable'; end if;
   select * into q from public.vora_product_stocks where product_id=s.id and business_id=p_business_id and outlet_code='MAIN' for update;
   if not found or q.quantity<v_qty then raise exception 'insufficient stock for %',s.name; end if;
   v_line:=s.sell_price*v_qty;
   v_sub:=v_sub+v_line;
   select coalesce(qualified_rate,0),coalesce(pv_per_unit,0),coalesce(cv_per_unit,0) into q from public.vora_product_qualification where product_id=s.id and business_id=p_business_id and active;
   v_qual:=v_qual+(v_line*coalesce(q.qualified_rate,0)/100);
   v_pv:=v_pv+(v_qty*coalesce(q.pv_per_unit,0));
   v_cv:=v_cv+(v_qty*coalesce(q.cv_per_unit,0));
 end loop;

 v_no:='VOR-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
 insert into public.vora_orders(business_id,order_no,seller_member_id,status,subtotal,total,qualified_amount,pv,cv,idempotency_key,paid_at,completed_at)
 values(p_business_id,v_no,p_seller_member_id,'completed',v_sub,v_sub,v_qual,v_pv,v_cv,p_idempotency_key,now(),now()) returning id into v_order;

 for r in select * from jsonb_array_elements(p_items) loop
   v_qty:=(r.value->>'quantity')::numeric;
   select * into s from public.vora_products where id=(r.value->>'product_id')::uuid and business_id=p_business_id;
   insert into public.vora_order_items(order_id,product_id,quantity,unit_price,line_total)
   values(v_order,s.id,v_qty,s.sell_price,s.sell_price*v_qty);
   update public.vora_product_stocks set quantity=quantity-v_qty,updated_at=now()
   where business_id=p_business_id and product_id=s.id and outlet_code='MAIN';
 end loop;
 insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
 values(p_business_id,auth.uid(),'order.create','vora_orders',v_order,jsonb_build_object('order_no',v_no,'total',v_sub,'qualified',v_qual,'pv',v_pv,'cv',v_cv));
 return v_order;
end $$;

create or replace function public.vora_settle_commission(p_order_id uuid)
returns numeric
language plpgsql
security definer
set search_path=''
as $$
declare o record; r record; c record; w record; amount numeric(18,2); total numeric(18,2):=0; key text; newbal numeric(18,2);
begin
 select * into o from public.vora_orders where id=p_order_id for update;
 if not found then raise exception 'order not found'; end if;
 if not public.vora_is_admin(o.business_id) then raise exception 'admin authorization required'; end if;
 if o.status<>'completed' then raise exception 'order is not completed'; end if;
 for r in select * from public.vora_commission_rules where business_id=o.business_id and active and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>=now()) order by rule_type,level loop
   if r.rule_type='direct_sales' then
     if o.seller_member_id is null then continue; end if;
     key:='order:'||o.id||':rule:'||r.id||':member:'||o.seller_member_id||':0';
     amount:=round(o.qualified_amount*r.rate/100+r.fixed_amount,2);
     if amount<=0 then continue; end if;
     insert into public.vora_commission_ledger(business_id,member_id,order_id,rule_id,entry_type,amount,source_key,description)
     values(o.business_id,o.seller_member_id,o.id,r.id,'credit',amount,key,'VORA direct sales commission') on conflict do nothing;
     if found then
       insert into public.vora_wallets(business_id,member_id) values(o.business_id,o.seller_member_id) on conflict do nothing;
       select * into w from public.vora_wallets where business_id=o.business_id and member_id=o.seller_member_id and currency='IDR' for update;
       newbal:=w.available_balance+amount;
       update public.vora_wallets set available_balance=newbal,updated_at=now() where id=w.id;
       insert into public.vora_wallet_transactions(wallet_id,business_id,member_id,direction,transaction_type,amount,balance_after,source_type,source_id,idempotency_key,description)
       values(w.id,o.business_id,o.seller_member_id,'credit','commission',amount,newbal,'order',o.id,key,'Direct sales commission');
       total:=total+amount;
     end if;
   elsif r.rule_type='unilevel' then
     for c in with recursive chain as(
       select m.id,m.sponsor_member_id,1 lvl from public.vora_members m where m.id=o.seller_member_id and m.business_id=o.business_id
       union all select p.id,p.sponsor_member_id,ch.lvl+1 from public.vora_members p join chain ch on ch.sponsor_member_id=p.id where p.business_id=o.business_id and ch.lvl<100
     ) select * from chain where lvl=coalesce(r.level,lvl) loop
       if r.level is not null and c.lvl<>r.level then continue; end if;
       key:='order:'||o.id||':rule:'||r.id||':member:'||c.id||':'||c.lvl;
       amount:=round(o.qualified_amount*r.rate/100+r.fixed_amount,2);
       if amount<=0 then continue; end if;
       insert into public.vora_commission_ledger(business_id,member_id,order_id,rule_id,entry_type,amount,source_key,description)
       values(o.business_id,c.id,o.id,r.id,'credit',amount,key,'VORA unilevel commission') on conflict do nothing;
       if found then
         insert into public.vora_wallets(business_id,member_id) values(o.business_id,c.id) on conflict do nothing;
         select * into w from public.vora_wallets where business_id=o.business_id and member_id=c.id and currency='IDR' for update;
         newbal:=w.available_balance+amount;
         update public.vora_wallets set available_balance=newbal,updated_at=now() where id=w.id;
         insert into public.vora_wallet_transactions(wallet_id,business_id,member_id,direction,transaction_type,amount,balance_after,source_type,source_id,idempotency_key,description)
         values(w.id,o.business_id,c.id,'credit','commission',amount,newbal,'order',o.id,key,'Unilevel commission');
         total:=total+amount;
       end if;
     end loop;
   end if;
 end loop;
 insert into public.vora_commission_runs(business_id,order_id,status,total_commission,completed_at) values(o.business_id,o.id,'completed',total,now())
 on conflict(business_id,order_id) do update set total_commission=excluded.total_commission,status='completed',completed_at=now();
 return total;
end $$;

revoke all on function public.vora_create_order(uuid,uuid,text,jsonb) from public;
grant execute on function public.vora_create_order(uuid,uuid,text,jsonb) to authenticated;
revoke all on function public.vora_settle_commission(uuid) from public;
grant execute on function public.vora_settle_commission(uuid) to authenticated;
