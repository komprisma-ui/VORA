-- VORA 2.2 Commerce-to-Wallet transaction engine
-- Server-side only. Idempotent order completion and commission settlement.

create or replace function public.vora_complete_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 o record; i record; q record; r record; u record;
 v_pv numeric:=0; v_cv numeric:=0; v_qualified numeric:=0; v_total_commission numeric:=0;
 v_commission numeric; v_level integer; v_source text; v_ancestor uuid; v_wallet_id uuid; v_balance numeric;
begin
 select * into o from public.vora_orders where id=p_order_id for update;
 if not found then raise exception 'order not found'; end if;
 if not public.vora_is_admin(o.business_id) and o.customer_user_id<>auth.uid() then raise exception 'not authorized'; end if;
 if o.status in('completed','refunded','cancelled') then
   return jsonb_build_object('order_id',o.id,'status',o.status,'idempotent',true);
 end if;
 if o.status<>'paid' then raise exception 'order must be paid before completion'; end if;

 for i in select * from public.vora_order_items where order_id=o.id loop
   select * into q from public.vora_product_qualification
   where business_id=o.business_id and product_id=i.product_id and active=true;
   if found then
     v_pv:=v_pv+(i.quantity*q.pv_per_unit);
     v_cv:=v_cv+(i.quantity*q.cv_per_unit);
     v_qualified:=v_qualified+(i.line_total*(q.qualified_rate/100));
   end if;
 end loop;

 update public.vora_orders
 set status='completed',completed_at=now(),qualified_amount=v_qualified,pv=v_pv,cv=v_cv
 where id=o.id;

 insert into public.vora_commission_runs(business_id,order_id,status,started_at)
 values(o.business_id,o.id,'processing',now())
 on conflict(business_id,order_id) do update set status='processing',started_at=now(),error_message=null;

 -- Direct sales commission.
 if o.seller_member_id is not null then
   for r in select * from public.vora_commission_rules
   where business_id=o.business_id and active=true and rule_type='direct_sales'
   and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>=now())
   order by id loop
     v_commission:=case when r.rate>0 then v_qualified*r.rate/100 else r.fixed_amount end;
     if v_commission>0 then
       v_source:='order:'||o.id::text||':rule:'||r.id::text;
       insert into public.vora_commission_ledger(business_id,member_id,order_id,rule_id,entry_type,amount,source_key,description)
       values(o.business_id,o.seller_member_id,o.id,r.id,'credit',v_commission,v_source,'Direct sales commission')
       on conflict(business_id,source_key) do nothing;
       if found then v_total_commission:=v_total_commission+v_commission; end if;
     end if;
   end loop;
 end if;

 -- Unilevel commission follows sponsor chain, bounded by configured rule levels.
 v_ancestor:=o.seller_member_id;
 v_level:=1;
 while v_ancestor is not null and v_level<=50 loop
   select sponsor_member_id into v_ancestor from public.vora_members
   where id=v_ancestor and business_id=o.business_id;
   exit when v_ancestor is null;
   for r in select * from public.vora_commission_rules
   where business_id=o.business_id and active=true and rule_type='unilevel' and level=v_level
   and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>=now()) loop
     v_commission:=case when r.rate>0 then v_qualified*r.rate/100 else r.fixed_amount end;
     if v_commission>0 then
       v_source:='order:'||o.id::text||':rule:'||r.id::text||':member:'||v_ancestor::text;
       insert into public.vora_commission_ledger(business_id,member_id,order_id,rule_id,entry_type,amount,source_key,description)
       values(o.business_id,v_ancestor,o.id,r.id,'credit',v_commission,v_source,'Unilevel commission')
       on conflict(business_id,source_key) do nothing;
       if found then v_total_commission:=v_total_commission+v_commission; end if;
     end if;
   end loop;
   v_level:=v_level+1;
 end loop;

 -- Convert posted commission into wallet balance exactly once per ledger entry.
 for r in select cl.* from public.vora_commission_ledger cl
   where cl.business_id=o.business_id and cl.order_id=o.id and cl.entry_type='credit' and cl.status='posted'
 loop
   insert into public.vora_wallets(business_id,member_id,currency)
   values(o.business_id,r.member_id,'IDR')
   on conflict(business_id,member_id,currency) do nothing;

   select id,available_balance into v_wallet_id,v_balance
   from public.vora_wallets where business_id=o.business_id and member_id=r.member_id and currency='IDR' for update;

   insert into public.vora_wallet_transactions(wallet_id,business_id,member_id,direction,transaction_type,amount,balance_after,source_type,source_id,idempotency_key,description)
   values(v_wallet_id,o.business_id,r.member_id,'credit','commission',r.amount,v_balance+r.amount,'commission',r.id,'commission-ledger:'||r.id::text,'Commission from order')
   on conflict(wallet_id,idempotency_key) do nothing;

   if found then
     update public.vora_wallets set available_balance=available_balance+r.amount,updated_at=now()
     where id=v_wallet_id;
   end if;
 end loop;

 update public.vora_commission_runs
 set status='completed',total_commission=v_total_commission,completed_at=now()
 where business_id=o.business_id and order_id=o.id;

 insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
 values(o.business_id,auth.uid(),'order.complete','vora_orders',o.id,
        jsonb_build_object('qualified_amount',v_qualified,'pv',v_pv,'cv',v_cv,'commission',v_total_commission));

 return jsonb_build_object('order_id',o.id,'status','completed','qualified_amount',v_qualified,'pv',v_pv,'cv',v_cv,'commission',v_total_commission);
exception when others then
 update public.vora_commission_runs set status='failed',error_message=sqlerrm,completed_at=now()
 where business_id=o.business_id and order_id=o.id;
 raise;
end $$;

-- Wallet withdrawal request is idempotent and atomically reserves available balance.
create or replace function public.vora_request_withdrawal(p_business_id uuid,p_amount numeric,p_destination jsonb,p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare m uuid; w record; id uuid;
begin
 select id into m from public.vora_members where business_id=p_business_id and user_id=auth.uid() and status='active' limit 1;
 if m is null then raise exception 'member not found'; end if;
 if p_amount<=0 then raise exception 'invalid amount'; end if;
 select * into w from public.vora_wallets where business_id=p_business_id and member_id=m and currency='IDR' and status='active' for update;
 if not found or w.available_balance<p_amount then raise exception 'insufficient available balance'; end if;
 select id into id from public.vora_withdrawals where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if id is not null then return id; end if;
 insert into public.vora_withdrawals(business_id,member_id,wallet_id,amount,fee,net_amount,status,destination,idempotency_key)
 values(p_business_id,m,w.id,p_amount,0,p_amount,'pending',coalesce(p_destination,'{}'::jsonb),p_idempotency_key)
 returning id into id;
 update public.vora_wallets set available_balance=available_balance-p_amount,pending_balance=pending_balance+p_amount,updated_at=now() where id=w.id;
 insert into public.vora_wallet_transactions(wallet_id,business_id,member_id,direction,transaction_type,amount,balance_after,source_type,source_id,idempotency_key,description)
 values(w.id,p_business_id,m,'debit','withdrawal_hold',p_amount,w.available_balance-p_amount,'withdrawal',id,'withdrawal-hold:'||id::text,'Withdrawal reserve');
 return id;
end $$;

revoke all on function public.vora_complete_order(uuid) from public;
revoke all on function public.vora_request_withdrawal(uuid,numeric,jsonb,text) from public;
grant execute on function public.vora_complete_order(uuid),public.vora_request_withdrawal(uuid,numeric,jsonb,text) to authenticated;

create index if not exists idx_vora_orders_completion_queue on public.vora_orders(business_id,status,paid_at desc);
create index if not exists idx_vora_ledger_order on public.vora_commission_ledger(business_id,order_id,created_at);
