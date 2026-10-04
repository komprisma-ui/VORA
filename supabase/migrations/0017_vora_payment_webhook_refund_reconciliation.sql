-- VORA 2.10 payment webhook, refund settlement and financial reconciliation
-- Provider signature verification is performed by the Edge Function before these service-role RPCs are called.

create table if not exists public.vora_financial_adjustments(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.vora_businesses(id) on delete cascade,
  member_id uuid not null references public.vora_members(id) on delete restrict,
  wallet_id uuid references public.vora_wallets(id) on delete restrict,
  order_id uuid references public.vora_orders(id) on delete restrict,
  refund_id uuid references public.vora_refunds(id) on delete restrict,
  adjustment_type text not null check(adjustment_type in('commission_reversal','commission_receivable','manual')),
  direction text not null check(direction in('debit','credit')),
  amount numeric(18,2) not null check(amount>0),
  status text not null default 'open' check(status in('open','settled','void')),
  idempotency_key text not null,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  unique(business_id,idempotency_key)
);

create index if not exists idx_vora_fin_adjustments_open
  on public.vora_financial_adjustments(business_id,status,member_id,created_at desc);

create table if not exists public.vora_financial_reconciliation_runs(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.vora_businesses(id) on delete cascade,
  status text not null default 'completed' check(status in('completed','failed')),
  orders_checked integer not null default 0,
  payments_checked integer not null default 0,
  refunds_checked integer not null default 0,
  wallet_members_checked integer not null default 0,
  exception_count integer not null default 0,
  report jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists idx_vora_recon_runs
  on public.vora_financial_reconciliation_runs(business_id,started_at desc);

alter table public.vora_financial_adjustments enable row level security;
alter table public.vora_financial_reconciliation_runs enable row level security;

drop policy if exists vora_fin_adjustments_admin_select on public.vora_financial_adjustments;
create policy vora_fin_adjustments_admin_select on public.vora_financial_adjustments
  for select to authenticated using(public.vora_is_admin(business_id));

drop policy if exists vora_recon_admin_select on public.vora_financial_reconciliation_runs;
create policy vora_recon_admin_select on public.vora_financial_reconciliation_runs
  for select to authenticated using(public.vora_is_admin(business_id));

revoke all on public.vora_financial_adjustments, public.vora_financial_reconciliation_runs from anon;
revoke all on public.vora_financial_adjustments, public.vora_financial_reconciliation_runs from authenticated;
grant select on public.vora_financial_adjustments, public.vora_financial_reconciliation_runs to authenticated;

create or replace function public.vora_record_payment_webhook(
  p_business_id uuid,
  p_provider text,
  p_provider_event_id text,
  p_event_type text,
  p_signature_verified boolean,
  p_payload jsonb
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'service role required'; end if;
  if not p_signature_verified then raise exception 'webhook signature not verified'; end if;
  if p_provider_event_id is null or length(trim(p_provider_event_id))<4 then raise exception 'invalid provider event id'; end if;
  insert into public.vora_payment_webhook_events(
    business_id,provider,provider_event_id,event_type,signature_verified,status,payload)
  values(p_business_id,p_provider,p_provider_event_id,p_event_type,true,'received',coalesce(p_payload,'{}'::jsonb))
  on conflict(business_id,provider,provider_event_id) do update
    set payload=excluded.payload,
        event_type=excluded.event_type,
        signature_verified=true
  returning id into v_id;
  return v_id;
end $$;

revoke all on function public.vora_record_payment_webhook(uuid,text,text,text,boolean,jsonb) from public;
grant execute on function public.vora_record_payment_webhook(uuid,text,text,text,boolean,jsonb) to service_role;

create or replace function public.vora_settle_refund(
  p_refund_id uuid,
  p_provider text,
  p_provider_reference text,
  p_provider_event_id text,
  p_idempotency_key text
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  f record; o record; pt record; cl record;
  v_total_refunded numeric; v_ratio numeric; v_reverse numeric;
  v_wallet_id uuid; v_balance numeric; v_reversed numeric:=0;
  v_key text; v_payment_id uuid;
begin
  if coalesce(auth.role(),'')<>'service_role' and not exists(
    select 1 from public.vora_refunds x
    where x.id=p_refund_id and public.vora_is_admin(x.business_id)
  ) then raise exception 'privileged settlement required'; end if;

  select * into f from public.vora_refunds where id=p_refund_id for update;
  if not found then raise exception 'refund not found'; end if;
  select * into o from public.vora_orders where id=f.order_id for update;
  if not found then raise exception 'order not found'; end if;
  if f.status='completed' then
    return jsonb_build_object('refund_id',f.id,'status','completed','idempotent',true);
  end if;
  if f.status<>'processing' then raise exception 'refund must be processing'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'invalid idempotency key'; end if;

  select coalesce(sum(amount),0) into v_total_refunded
  from public.vora_refunds
  where order_id=o.id and status='completed' and id<>f.id;
  if v_total_refunded+f.amount>o.total then raise exception 'refund exceeds captured order amount'; end if;

  select * into pt from public.vora_payment_transactions
    where order_id=o.id and status in('paid','partially_refunded')
    order by created_at desc limit 1 for update;
  if not found then raise exception 'captured payment not found'; end if;
  v_payment_id:=pt.id;

  -- Reverse only the commission that was actually posted for this order.
  v_ratio:=least(1,f.amount/nullif(o.total,0));
  for cl in
    select * from public.vora_commission_ledger
    where business_id=o.business_id and order_id=o.id
      and entry_type='credit' and status='posted'
  loop
    v_reverse:=round(cl.amount*v_ratio,2);
    if v_reverse<=0 then continue; end if;
    v_key:='refund:'||f.id||':ledger:'||cl.id;
    insert into public.vora_commission_ledger(
      business_id,member_id,order_id,rule_id,entry_type,amount,source_key,related_entry_id,status,description)
    values(o.business_id,cl.member_id,o.id,cl.rule_id,'reversal',v_reverse,v_key,cl.id,'posted','Refund commission reversal')
    on conflict(business_id,source_key) do nothing;

    if found then
      insert into public.vora_wallets(business_id,member_id,currency)
        values(o.business_id,cl.member_id,'IDR')
        on conflict(business_id,member_id,currency) do nothing;
      select id,available_balance into v_wallet_id,v_balance
        from public.vora_wallets
        where business_id=o.business_id and member_id=cl.member_id and currency='IDR'
        for update;
      if v_balance>=v_reverse then
        insert into public.vora_wallet_transactions(
          wallet_id,business_id,member_id,direction,transaction_type,amount,balance_after,
          source_type,source_id,idempotency_key,description)
        values(v_wallet_id,o.business_id,cl.member_id,'debit','commission_refund',
          v_reverse,v_balance-v_reverse,'refund',f.id,
          'refund-wallet:'||f.id||':ledger:'||cl.id,'Commission reversal for refund');
        update public.vora_wallets set available_balance=available_balance-v_reverse,updated_at=now()
          where id=v_wallet_id;
        update public.vora_financial_adjustments set status='settled',settled_at=now()
          where business_id=o.business_id and idempotency_key='receivable:'||f.id||':'||cl.id and status='open';
      else
        insert into public.vora_financial_adjustments(
          business_id,member_id,wallet_id,order_id,refund_id,adjustment_type,direction,amount,
          idempotency_key,description)
        values(o.business_id,cl.member_id,v_wallet_id,o.id,f.id,'commission_receivable','debit',
          v_reverse-v_balance,'receivable:'||f.id||':'||cl.id,
          'Commission clawback receivable after refund')
        on conflict(business_id,idempotency_key) do nothing;
        if v_balance>0 then
          insert into public.vora_wallet_transactions(
            wallet_id,business_id,member_id,direction,transaction_type,amount,balance_after,
            source_type,source_id,idempotency_key,description)
          values(v_wallet_id,o.business_id,cl.member_id,'debit','commission_refund',
            v_balance,0,'refund',f.id,'refund-wallet:'||f.id||':ledger:'||cl.id,
            'Partial commission reversal; remaining amount receivable');
          update public.vora_wallets set available_balance=0,updated_at=now() where id=v_wallet_id;
        end if;
      end if;
      v_reversed:=v_reversed+v_reverse;
    end if;
  end loop;

  update public.vora_payment_transactions
    set status=case when v_total_refunded+f.amount>=pt.amount then 'refunded' else 'partially_refunded' end,
        updated_at=now()
    where id=v_payment_id;

  update public.vora_refunds
    set status='completed',payment_transaction_id=v_payment_id,provider_reference=p_provider_reference,
        processed_at=now()
    where id=f.id;

  if v_total_refunded+f.amount>=o.total then
    update public.vora_orders set status='refunded' where id=o.id;
  end if;

  insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
  values(o.business_id,auth.uid(),'refund.settled','vora_refunds',f.id,
    jsonb_build_object('provider',p_provider,'provider_reference',p_provider_reference,
      'provider_event_id',p_provider_event_id,'payment_id',v_payment_id,'commission_reversed',v_reversed));
  return jsonb_build_object('refund_id',f.id,'status','completed','payment_id',v_payment_id,
    'commission_reversed',v_reversed);
end $$;

alter table public.vora_refunds add column if not exists provider_reference text;
create index if not exists idx_vora_refunds_provider_reference
  on public.vora_refunds(business_id,provider_reference);

revoke all on function public.vora_settle_refund(uuid,text,text,text,text) from public;
grant execute on function public.vora_settle_refund(uuid,text,text,text,text) to service_role,authenticated;

create or replace function public.vora_financial_reconciliation(p_business_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_run uuid; v_orders int:=0; v_payments int:=0; v_refunds int:=0; v_wallets int:=0; v_ex int:=0;
  v_payment_ex jsonb:='[]'::jsonb; v_refund_ex jsonb:='[]'::jsonb; v_wallet_ex jsonb:='[]'::jsonb;
  x record; v_ledger numeric; v_wallet numeric; v_expected numeric;
begin
  if not public.vora_is_admin(p_business_id) and coalesce(auth.role(),'')<>'service_role' then raise exception 'admin required'; end if;
  insert into public.vora_financial_reconciliation_runs(business_id,status,started_at)
    values(p_business_id,'completed',now()) returning id into v_run;

  select count(*) into v_orders from public.vora_orders where business_id=p_business_id;
  select count(*) into v_payments from public.vora_payment_transactions where business_id=p_business_id;
  select count(*) into v_refunds from public.vora_refunds where business_id=p_business_id;
  select count(*) into v_wallets from public.vora_wallets where business_id=p_business_id;

  for x in
    select p.id,p.order_id,p.amount,o.total,o.status,p.status payment_status
    from public.vora_payment_transactions p join public.vora_orders o on o.id=p.order_id
    where p.business_id=p_business_id
      and p.status='paid' and o.status in('pending','cancelled')
  loop
    v_ex:=v_ex+1;
    v_payment_ex:=v_payment_ex||jsonb_build_array(jsonb_build_object(
      'type','payment_order_mismatch','payment_id',x.id,'order_id',x.order_id,
      'payment_status',x.payment_status,'order_status',x.status));
  end loop;

  for x in
    select f.id,f.order_id,f.amount,f.status,o.total
    from public.vora_refunds f join public.vora_orders o on o.id=f.order_id
    where f.business_id=p_business_id and f.status='completed'
      and not exists(select 1 from public.vora_payment_transactions p
        where p.id=f.payment_transaction_id and p.status in('refunded','partially_refunded'))
  loop
    v_ex:=v_ex+1;
    v_refund_ex:=v_refund_ex||jsonb_build_array(jsonb_build_object(
      'type','refund_payment_mismatch','refund_id',x.id,'order_id',x.order_id,'amount',x.amount));
  end loop;

  for x in
    select w.id,w.member_id,w.available_balance,
      coalesce((select sum(case when direction='credit' then amount else -amount end)
        from public.vora_wallet_transactions t where t.wallet_id=w.id),0) ledger_balance
    from public.vora_wallets w where w.business_id=p_business_id
  loop
    if round(x.available_balance,2)<>round(x.ledger_balance,2) then
      v_ex:=v_ex+1;
      v_wallet_ex:=v_wallet_ex||jsonb_build_array(jsonb_build_object(
        'type','wallet_balance_mismatch','wallet_id',x.id,'member_id',x.member_id,
        'wallet_balance',x.available_balance,'ledger_balance',x.ledger_balance));
    end if;
  end loop;

  update public.vora_financial_reconciliation_runs
    set orders_checked=v_orders,payments_checked=v_payments,refunds_checked=v_refunds,
        wallet_members_checked=v_wallets,exception_count=v_ex,
        report=jsonb_build_object('payment_exceptions',v_payment_ex,
          'refund_exceptions',v_refund_ex,'wallet_exceptions',v_wallet_ex),
        completed_at=now()
    where id=v_run;

  return jsonb_build_object('run_id',v_run,'status','completed','exception_count',v_ex,
    'orders_checked',v_orders,'payments_checked',v_payments,'refunds_checked',v_refunds,
    'wallet_members_checked',v_wallets,'payment_exceptions',v_payment_ex,
    'refund_exceptions',v_refund_ex,'wallet_exceptions',v_wallet_ex);
exception when others then
  if v_run is not null then
    update public.vora_financial_reconciliation_runs
      set status='failed',exception_count=v_ex,completed_at=now(),
          report=jsonb_build_object('error',sqlerrm) where id=v_run;
  end if;
  raise;
end $$;

revoke all on function public.vora_financial_reconciliation(uuid) from public;
grant execute on function public.vora_financial_reconciliation(uuid) to service_role,authenticated;
