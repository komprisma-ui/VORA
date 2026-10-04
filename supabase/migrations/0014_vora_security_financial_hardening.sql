-- VORA 2.7 security and financial control hardening
-- Close legacy transaction paths and ensure payment/settlement are server-controlled.

revoke execute on function public.vora_create_order(uuid,uuid,text,jsonb) from authenticated;
revoke execute on function public.vora_settle_commission(uuid) from authenticated;

revoke execute on function public.vora_release_order_reservation(uuid) from authenticated;
revoke execute on function public.vora_release_expired_reservations(integer) from authenticated;

create or replace function public.vora_record_payment(
  p_business_id uuid,
  p_order_id uuid,
  p_provider text,
  p_amount numeric,
  p_status text,
  p_provider_reference text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  o record;
  pid uuid;
begin
  if not public.vora_is_admin(p_business_id) then
    raise exception 'payment processing requires privileged backend/admin';
  end if;

  if p_status not in ('pending','authorized','paid','failed','expired','refunded','partially_refunded') then
    raise exception 'invalid payment status';
  end if;

  select * into o
  from public.vora_orders
  where id=p_order_id and business_id=p_business_id
  for update;

  if not found then raise exception 'order not found'; end if;
  if p_amount<=0 or p_amount<>o.total then raise exception 'payment amount mismatch'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then
    raise exception 'invalid idempotency key';
  end if;

  select id into pid
  from public.vora_payment_transactions
  where business_id=p_business_id and idempotency_key=p_idempotency_key;

  if pid is not null then return pid; end if;

  insert into public.vora_payment_transactions(
    business_id,order_id,provider,provider_reference,status,amount,idempotency_key
  )
  values(
    p_business_id,p_order_id,p_provider,p_provider_reference,p_status,p_amount,p_idempotency_key
  )
  returning id into pid;

  if p_status='paid' then
    update public.vora_orders
    set status='paid', paid_at=coalesce(paid_at,now())
    where id=p_order_id and status in ('pending','paid');
  elsif p_status in ('failed','expired') then
    update public.vora_orders
    set status='cancelled'
    where id=p_order_id and status='pending';
  end if;

  insert into public.vora_audit_logs(
    business_id,actor_user_id,action,entity,entity_id,after_data
  )
  values(
    p_business_id,auth.uid(),'payment.recorded','vora_orders',p_order_id,
    jsonb_build_object(
      'payment_id',pid,
      'provider',p_provider,
      'provider_reference',p_provider_reference,
      'status',p_status,
      'amount',p_amount
    )
  );

  return pid;
end $$;

revoke all on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text) from public;
grant execute on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text) to authenticated;

create table if not exists public.vora_payment_webhook_events(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.vora_businesses(id) on delete cascade,
  provider text not null,
  provider_event_id text not null,
  event_type text not null,
  signature_verified boolean not null default false,
  status text not null default 'received'
    check(status in('received','processing','processed','ignored','failed')),
  payload jsonb not null default '{}'::jsonb,
  error_message text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique(business_id,provider,provider_event_id)
);

create index if not exists idx_vora_payment_webhook_status
  on public.vora_payment_webhook_events(business_id,status,received_at desc);

alter table public.vora_payment_webhook_events enable row level security;

drop policy if exists vora_payment_webhook_admin_select
  on public.vora_payment_webhook_events;

create policy vora_payment_webhook_admin_select
  on public.vora_payment_webhook_events
  for select to authenticated
  using(public.vora_is_admin(business_id));

revoke all on public.vora_payment_webhook_events from anon;
revoke all on public.vora_payment_webhook_events from authenticated;
grant select on public.vora_payment_webhook_events to authenticated;

-- Completion is a financial settlement operation and must not be customer-triggerable.
create or replace function public.vora_complete_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  o record;
  i record;
  q record;
  r record;
  v_pv numeric:=0;
  v_cv numeric:=0;
  v_qualified numeric:=0;
  v_total_commission numeric:=0;
  v_commission numeric;
  v_level integer;
  v_source text;
  v_ancestor uuid;
  v_wallet_id uuid;
  v_balance numeric;
begin
  select * into o from public.vora_orders where id=p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if not public.vora_is_admin(o.business_id) then raise exception 'settlement requires privileged backend/admin'; end if;

  if o.status in('completed','refunded','cancelled') then
    return jsonb_build_object('order_id',o.id,'status',o.status,'idempotent',true);
  end if;
  if o.status<>'paid' then raise exception 'order must be paid before completion'; end if;

  if exists(
    select 1 from public.vora_commission_runs
    where business_id=o.business_id and order_id=o.id and status='completed'
  ) then
    update public.vora_orders
    set status='completed',completed_at=coalesce(completed_at,now())
    where id=o.id;
    return jsonb_build_object('order_id',o.id,'status','completed','idempotent',true);
  end if;

  for i in select * from public.vora_order_items where order_id=o.id loop
    select * into q
    from public.vora_product_qualification
    where business_id=o.business_id and product_id=i.product_id and active=true;

    if found then
      v_pv:=v_pv+(i.quantity*q.pv_per_unit);
      v_cv:=v_cv+(i.quantity*q.cv_per_unit);
      v_qualified:=v_qualified+(i.line_total*q.qualified_rate/100);
    end if;
  end loop;

  update public.vora_orders
  set status='completed',completed_at=now(),
      qualified_amount=v_qualified,pv=v_pv,cv=v_cv
  where id=o.id;

  insert into public.vora_commission_runs(business_id,order_id,status,started_at)
  values(o.business_id,o.id,'processing',now())
  on conflict(business_id,order_id)
  do update set status='processing',started_at=now(),error_message=null;

  if o.seller_member_id is not null then
    for r in
      select * from public.vora_commission_rules
      where business_id=o.business_id and active=true and rule_type='direct_sales'
        and (starts_at is null or starts_at<=now())
        and (ends_at is null or ends_at>=now())
      order by id
    loop
      v_commission:=case when r.rate>0 then v_qualified*r.rate/100 else r.fixed_amount end;
      if v_commission>0 then
        v_source:='order:'||o.id||':rule:'||r.id;
        insert into public.vora_commission_ledger(
          business_id,member_id,order_id,rule_id,entry_type,amount,source_key,description
        )
        values(
          o.business_id,o.seller_member_id,o.id,r.id,'credit',
          v_commission,v_source,'Direct sales commission'
        )
        on conflict(business_id,source_key) do nothing;
        if found then v_total_commission:=v_total_commission+v_commission; end if;
      end if;
    end loop;
  end if;

  v_ancestor:=o.seller_member_id;
  v_level:=1;

  while v_ancestor is not null and v_level<=50 loop
    select sponsor_member_id into v_ancestor
    from public.vora_members
    where id=v_ancestor and business_id=o.business_id;

    exit when v_ancestor is null;

    for r in
      select * from public.vora_commission_rules
      where business_id=o.business_id and active=true and rule_type='unilevel' and level=v_level
        and (starts_at is null or starts_at<=now())
        and (ends_at is null or ends_at>=now())
    loop
      v_commission:=case when r.rate>0 then v_qualified*r.rate/100 else r.fixed_amount end;

      if v_commission>0 then
        v_source:='order:'||o.id||':rule:'||r.id||':member:'||v_ancestor;

        insert into public.vora_commission_ledger(
          business_id,member_id,order_id,rule_id,entry_type,amount,source_key,description
        )
        values(
          o.business_id,v_ancestor,o.id,r.id,'credit',
          v_commission,v_source,'Unilevel commission'
        )
        on conflict(business_id,source_key) do nothing;

        if found then v_total_commission:=v_total_commission+v_commission; end if;
      end if;
    end loop;

    v_level:=v_level+1;
  end loop;

  for r in
    select cl.*
    from public.vora_commission_ledger cl
    where cl.business_id=o.business_id
      and cl.order_id=o.id
      and cl.entry_type='credit'
      and cl.status='posted'
  loop
    insert into public.vora_wallets(business_id,member_id,currency)
    values(o.business_id,r.member_id,'IDR')
    on conflict(business_id,member_id,currency) do nothing;

    select id,available_balance into v_wallet_id,v_balance
    from public.vora_wallets
    where business_id=o.business_id and member_id=r.member_id and currency='IDR'
    for update;

    insert into public.vora_wallet_transactions(
      wallet_id,business_id,member_id,direction,transaction_type,amount,
      balance_after,source_type,source_id,idempotency_key,description
    )
    values(
      v_wallet_id,o.business_id,r.member_id,'credit','commission',
      r.amount,v_balance+r.amount,'commission',r.id,
      'commission-ledger:'||r.id,'Commission from order'
    )
    on conflict(wallet_id,idempotency_key) do nothing;

    if found then
      update public.vora_wallets
      set available_balance=available_balance+r.amount,updated_at=now()
      where id=v_wallet_id;
    end if;
  end loop;

  update public.vora_commission_runs
  set status='completed',total_commission=v_total_commission,completed_at=now()
  where business_id=o.business_id and order_id=o.id;

  insert into public.vora_audit_logs(
    business_id,actor_user_id,action,entity,entity_id,after_data
  )
  values(
    o.business_id,auth.uid(),'order.complete','vora_orders',o.id,
    jsonb_build_object(
      'qualified_amount',v_qualified,
      'pv',v_pv,
      'cv',v_cv,
      'commission',v_total_commission
    )
  );

  return jsonb_build_object(
    'order_id',o.id,'status','completed',
    'qualified_amount',v_qualified,'pv',v_pv,'cv',v_cv,
    'commission',v_total_commission
  );
exception when others then
  update public.vora_commission_runs
  set status='failed',error_message=sqlerrm,completed_at=now()
  where business_id=o.business_id and order_id=o.id;
  raise;
end $$;

revoke all on function public.vora_complete_order(uuid) from public;
grant execute on function public.vora_complete_order(uuid) to authenticated;
