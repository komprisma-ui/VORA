-- VORA 2.11 financial reconciliation completion hardening
-- Adds visibility for open commission receivables and prevents silent financial debt accumulation.

alter table public.vora_financial_adjustments
  add column if not exists settled_at timestamptz;

create index if not exists idx_vora_financial_adjustments_open_receivable
  on public.vora_financial_adjustments(business_id,member_id,created_at desc)
  where adjustment_type='commission_receivable' and status='open';

create or replace function public.vora_financial_reconciliation(p_business_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_run uuid; v_orders int:=0; v_payments int:=0; v_refunds int:=0; v_wallets int:=0;
  v_receivables int:=0; v_ex int:=0;
  v_payment_ex jsonb:='[]'::jsonb; v_refund_ex jsonb:='[]'::jsonb;
  v_wallet_ex jsonb:='[]'::jsonb; v_receivable_ex jsonb:='[]'::jsonb;
  x record;
begin
  if not public.vora_is_admin(p_business_id) and coalesce(auth.role(),'')<>'service_role'
    then raise exception 'admin required'; end if;

  insert into public.vora_financial_reconciliation_runs(business_id,status,started_at)
    values(p_business_id,'completed',now()) returning id into v_run;

  select count(*) into v_orders from public.vora_orders where business_id=p_business_id;
  select count(*) into v_payments from public.vora_payment_transactions where business_id=p_business_id;
  select count(*) into v_refunds from public.vora_refunds where business_id=p_business_id;
  select count(*) into v_wallets from public.vora_wallets where business_id=p_business_id;

  for x in
    select p.id,p.order_id,p.status payment_status,o.status order_status
    from public.vora_payment_transactions p join public.vora_orders o on o.id=p.order_id
    where p.business_id=p_business_id and p.status='paid' and o.status in('pending','cancelled')
  loop
    v_ex:=v_ex+1;
    v_payment_ex:=v_payment_ex||jsonb_build_array(jsonb_build_object(
      'type','payment_order_mismatch','payment_id',x.id,'order_id',x.order_id,
      'payment_status',x.payment_status,'order_status',x.order_status));
  end loop;

  for x in
    select f.id,f.order_id,f.amount
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

  for x in
    select id,member_id,refund_id,order_id,amount,created_at
    from public.vora_financial_adjustments
    where business_id=p_business_id and adjustment_type='commission_receivable' and status='open'
  loop
    v_receivables:=v_receivables+1;
    v_ex:=v_ex+1;
    v_receivable_ex:=v_receivable_ex||jsonb_build_array(jsonb_build_object(
      'type','open_commission_receivable','adjustment_id',x.id,'member_id',x.member_id,
      'refund_id',x.refund_id,'order_id',x.order_id,'amount',x.amount,'created_at',x.created_at));
  end loop;

  update public.vora_financial_reconciliation_runs
    set orders_checked=v_orders,payments_checked=v_payments,refunds_checked=v_refunds,
        wallet_members_checked=v_wallets,exception_count=v_ex,
        report=jsonb_build_object(
          'payment_exceptions',v_payment_ex,'refund_exceptions',v_refund_ex,
          'wallet_exceptions',v_wallet_ex,'open_commission_receivables',v_receivable_ex),
        completed_at=now()
    where id=v_run;

  return jsonb_build_object(
    'run_id',v_run,'status','completed','exception_count',v_ex,
    'orders_checked',v_orders,'payments_checked',v_payments,'refunds_checked',v_refunds,
    'wallet_members_checked',v_wallets,'open_commission_receivables',v_receivables,
    'payment_exceptions',v_payment_ex,'refund_exceptions',v_refund_ex,
    'wallet_exceptions',v_wallet_ex,'receivable_exceptions',v_receivable_ex);
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
