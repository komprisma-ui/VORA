-- VORA 2.13 provider idempotency and state-transition hardening
-- Fix repeated provider notifications and prevent order status regression.

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
  existing record;
  pid uuid;
  v_current_rank integer;
  v_incoming_rank integer;
begin
  if coalesce(auth.role(),'')<>'service_role'
     and not public.vora_is_admin(p_business_id) then
    raise exception 'payment processing requires privileged backend/admin';
  end if;

  if p_status not in ('pending','authorized','paid','failed','expired','refunded','partially_refunded') then
    raise exception 'invalid payment status';
  end if;

  if p_amount<=0
     or p_idempotency_key is null
     or length(trim(p_idempotency_key))<8 then
    raise exception 'invalid payment request';
  end if;

  select * into o
  from public.vora_orders
  where id=p_order_id and business_id=p_business_id
  for update;

  if not found then raise exception 'order not found'; end if;
  if p_amount<>o.total then raise exception 'payment amount mismatch'; end if;

  -- First idempotency guard: the same webhook event can be retried.
  select * into existing
  from public.vora_payment_transactions
  where business_id=p_business_id
    and idempotency_key=p_idempotency_key
  for update;

  if found then
    return existing.id;
  end if;

  -- Second idempotency guard: one provider transaction can emit multiple
  -- notifications (pending -> settlement, retries, etc.).
  if nullif(trim(coalesce(p_provider_reference,'')),'') is not null then
    select * into existing
    from public.vora_payment_transactions
    where business_id=p_business_id
      and provider=p_provider
      and provider_reference=p_provider_reference
    for update;

    if found then
      if existing.order_id<>p_order_id then
        raise exception 'provider reference belongs to another order';
      end if;
      if existing.amount<>p_amount then
        raise exception 'provider payment amount mismatch';
      end if;

      -- Never downgrade a financial state because a stale provider
      -- notification arrived after a newer notification.
      if existing.status in ('paid','refunded','partially_refunded')
         and p_status in ('pending','authorized','failed','expired') then
        return existing.id;
      end if;

      v_current_rank:=case existing.status
        when 'pending' then 10
        when 'authorized' then 20
        when 'paid' then 30
        when 'failed' then 15
        when 'expired' then 15
        when 'partially_refunded' then 40
        when 'refunded' then 50
        else 0 end;

      v_incoming_rank:=case p_status
        when 'pending' then 10
        when 'authorized' then 20
        when 'paid' then 30
        when 'failed' then 15
        when 'expired' then 15
        when 'partially_refunded' then 40
        when 'refunded' then 50
        else 0 end;

      if v_incoming_rank<v_current_rank then
        return existing.id;
      end if;

      update public.vora_payment_transactions
        set status=p_status,updated_at=now()
        where id=existing.id;

      if p_status='paid' and o.status='pending' then
        update public.vora_orders
          set status='paid',paid_at=coalesce(paid_at,now())
          where id=o.id;
      elsif p_status in ('failed','expired') and o.status='pending' then
        update public.vora_orders
          set status='cancelled'
          where id=o.id;
        perform public.vora_release_order_reservation(o.id);
      end if;

      insert into public.vora_audit_logs(
        business_id,actor_user_id,action,entity,entity_id,after_data
      )
      values(
        p_business_id,auth.uid(),'payment.status_updated',
        'vora_orders',o.id,
        jsonb_build_object(
          'payment_id',existing.id,
          'provider',p_provider,
          'status',p_status,
          'amount',p_amount,
          'provider_reference',p_provider_reference
        )
      );

      return existing.id;
    end if;
  end if;

  insert into public.vora_payment_transactions(
    business_id,order_id,provider,provider_reference,status,amount,idempotency_key
  )
  values(
    p_business_id,p_order_id,p_provider,
    nullif(trim(coalesce(p_provider_reference,'')),''),
    p_status,p_amount,p_idempotency_key
  )
  returning id into pid;

  if p_status='paid' and o.status='pending' then
    update public.vora_orders
      set status='paid',paid_at=coalesce(paid_at,now())
      where id=p_order_id;
  elsif p_status in ('failed','expired') and o.status='pending' then
    update public.vora_orders
      set status='cancelled'
      where id=p_order_id;
    perform public.vora_release_order_reservation(p_order_id);
  end if;

  insert into public.vora_audit_logs(
    business_id,actor_user_id,action,entity,entity_id,after_data
  )
  values(
    p_business_id,auth.uid(),'payment.recorded','vora_orders',p_order_id,
    jsonb_build_object(
      'payment_id',pid,
      'provider',p_provider,
      'status',p_status,
      'amount',p_amount
    )
  );

  return pid;
end $$;

revoke all on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text)
  from anon,public;
grant execute on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text)
  to authenticated;

-- Prevent operational state regression. A pending status is only valid
-- while the order is already pending.
create or replace function public.vora_update_order_status(
  p_order_id uuid,
  p_status text
)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare o record;
begin
  select * into o
  from public.vora_orders
  where id=p_order_id
  for update;

  if not found then raise exception 'order not found'; end if;
  if not public.vora_is_admin(o.business_id) then raise exception 'admin required'; end if;

  if p_status not in ('pending','processing','shipped','cancelled') then
    raise exception 'use dedicated payment/completion/refund workflow for this status';
  end if;

  if o.status in ('completed','refunded','cancelled') then
    raise exception 'order is terminal';
  end if;

  if p_status='pending' and o.status<>'pending' then
    raise exception 'cannot regress order to pending';
  end if;

  if p_status='cancelled' and o.status<>'pending' then
    raise exception 'paid orders must use refund workflow';
  end if;

  if p_status='processing' and o.status<>'paid' then
    raise exception 'processing requires paid order';
  end if;

  if p_status='shipped' and o.status<>'processing' then
    raise exception 'shipped requires processing order';
  end if;

  update public.vora_orders
    set status=p_status
    where id=p_order_id;

  if p_status='cancelled' then
    perform public.vora_release_order_reservation(p_order_id);
  end if;

  insert into public.vora_audit_logs(
    business_id,actor_user_id,action,entity,entity_id,after_data
  )
  values(
    o.business_id,auth.uid(),'order.status_changed','vora_orders',p_order_id,
    jsonb_build_object('from',o.status,'to',p_status)
  );

  return true;
end $$;

revoke all on function public.vora_update_order_status(uuid,text) from public;
grant execute on function public.vora_update_order_status(uuid,text) to authenticated;
