-- VORA 2.8 financial state-machine hardening
-- Keep historical migrations immutable; all corrections are additive.

create or replace function public.vora_update_withdrawal_status(
  p_withdrawal_id uuid,
  p_status text,
  p_fee numeric default null
)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare w record;
begin
  select * into w from public.vora_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  if not public.vora_is_admin(w.business_id) then raise exception 'admin required'; end if;
  if p_status not in ('approved','processing','paid','rejected','cancelled') then raise exception 'invalid withdrawal status'; end if;
  if w.status in ('paid','rejected','cancelled') then raise exception 'withdrawal is terminal'; end if;

  if p_status='approved' and w.status<>'pending' then raise exception 'invalid transition'; end if;
  if p_status='processing' and w.status not in ('pending','approved') then raise exception 'invalid transition'; end if;
  if p_status='paid' and w.status not in ('processing','approved') then raise exception 'invalid transition'; end if;
  if p_status in ('rejected','cancelled') and w.status not in ('pending','approved') then raise exception 'invalid transition'; end if;

  if p_status='paid' then
    update public.vora_wallets
      set pending_balance=greatest(0,pending_balance-w.amount),updated_at=now()
      where id=w.wallet_id;
  elsif p_status in ('rejected','cancelled') then
    update public.vora_wallets
      set available_balance=available_balance+w.amount,
          pending_balance=greatest(0,pending_balance-w.amount),
          updated_at=now()
      where id=w.wallet_id;
  end if;

  update public.vora_withdrawals
  set status=p_status,
      fee=coalesce(p_fee,fee),
      net_amount=greatest(0,amount-coalesce(p_fee,fee)),
      processed_at=case when p_status in ('paid','rejected','cancelled') then now() else processed_at end
  where id=w.id;

  insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
  values(w.business_id,auth.uid(),'withdrawal.status_changed','vora_withdrawals',w.id,
    jsonb_build_object('from',w.status,'to',p_status,'fee',coalesce(p_fee,w.fee)));
  return true;
end $$;

revoke all on function public.vora_update_withdrawal_status(uuid,text,numeric) from public;
grant execute on function public.vora_update_withdrawal_status(uuid,text,numeric) to authenticated;

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
declare o record; pid uuid;
begin
  if coalesce(auth.role(),'')<>'service_role' and not public.vora_is_admin(p_business_id) then
    raise exception 'payment processing requires privileged backend/admin';
  end if;
  if p_status not in ('pending','authorized','paid','failed','expired','refunded','partially_refunded') then
    raise exception 'invalid payment status';
  end if;
  if p_amount<=0 or p_idempotency_key is null or length(trim(p_idempotency_key))<8 then
    raise exception 'invalid payment request';
  end if;

  select * into o from public.vora_orders where id=p_order_id and business_id=p_business_id for update;
  if not found then raise exception 'order not found'; end if;
  if p_amount<>o.total then raise exception 'payment amount mismatch'; end if;

  select id into pid from public.vora_payment_transactions
    where business_id=p_business_id and idempotency_key=p_idempotency_key;
  if pid is not null then return pid; end if;

  insert into public.vora_payment_transactions
    (business_id,order_id,provider,provider_reference,status,amount,idempotency_key)
  values
    (p_business_id,p_order_id,p_provider,p_provider_reference,p_status,p_amount,p_idempotency_key)
  returning id into pid;

  if p_status='paid' then
    update public.vora_orders set status='paid',paid_at=coalesce(paid_at,now())
      where id=p_order_id and status='pending';
  elsif p_status in ('failed','expired') then
    update public.vora_orders set status='cancelled'
      where id=p_order_id and status='pending';
    perform public.vora_release_order_reservation(p_order_id);
  end if;

  insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
  values(p_business_id,auth.uid(),'payment.recorded','vora_orders',p_order_id,
    jsonb_build_object('payment_id',pid,'provider',p_provider,'status',p_status,'amount',p_amount));
  return pid;
end $$;

revoke all on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text) from public;
grant execute on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text) to authenticated;

-- Refund requests are no longer auto-completed. Completion remains a controlled transition.
create or replace function public.vora_refund_order(
  p_order_id uuid,
  p_amount numeric,
  p_reason text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare o record; f uuid;
begin
  select * into o from public.vora_orders where id=p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if not public.vora_is_admin(o.business_id) then raise exception 'admin required'; end if;
  if p_amount<=0 or p_amount>o.total then raise exception 'invalid refund amount'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'invalid idempotency key'; end if;

  select id into f from public.vora_refunds
    where business_id=o.business_id and idempotency_key=p_idempotency_key;
  if f is not null then return f; end if;

  insert into public.vora_refunds(
    business_id,order_id,amount,reason,status,idempotency_key,requested_by
  ) values(
    o.business_id,o.id,p_amount,coalesce(p_reason,'Customer refund'),
    'requested',p_idempotency_key,auth.uid()
  ) returning id into f;

  insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
  values(o.business_id,auth.uid(),'refund.requested','vora_orders',o.id,
    jsonb_build_object('refund_id',f,'amount',p_amount,'reason',p_reason));
  return f;
end $$;

revoke all on function public.vora_refund_order(uuid,numeric,text,text) from public;
grant execute on function public.vora_refund_order(uuid,numeric,text,text) to authenticated;
