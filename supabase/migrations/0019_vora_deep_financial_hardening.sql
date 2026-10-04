-- VORA 2.12 deep financial/order state hardening
-- Prevent manual state bypasses, consume reservations on completion,
-- keep wallet ledger balanced on withdrawal reversal, and deduplicate provider references.

-- 1. Provider references must be unique per business/provider when present.
create unique index if not exists uq_vora_payment_provider_reference
  on public.vora_payment_transactions(business_id,provider,provider_reference)
  where provider_reference is not null;

create unique index if not exists uq_vora_refund_provider_reference
  on public.vora_refunds(business_id,provider_reference)
  where provider_reference is not null;

-- 2. Order status changes are restricted to operational transitions.
-- Financial transitions (paid/completed/refunded) must use their dedicated engines.
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

-- 3. Completion consumes all still-reserved inventory in the same transaction.
create or replace function public.vora_complete_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  o record; i record; q record; r record;
  v_pv numeric:=0; v_cv numeric:=0; v_qualified numeric:=0;
  v_total_commission numeric:=0; v_commission numeric;
  v_level integer; v_source text; v_ancestor uuid; v_visited uuid[]:=array[]::uuid[];
  v_wallet_id uuid; v_balance numeric;
begin
  select * into o from public.vora_orders where id=p_order_id for update;
  if not found then raise exception 'order not found'; end if;

  if coalesce(auth.role(),'')<>'service_role'
     and not public.vora_is_admin(o.business_id) then
    raise exception 'settlement requires privileged backend/admin';
  end if;

  if o.status in('completed','refunded','cancelled') then
    return jsonb_build_object('order_id',o.id,'status',o.status,'idempotent',true);
  end if;

  if o.status not in ('paid','processing','shipped') then
    raise exception 'order must be paid/processing/shipped before completion';
  end if;

  if exists(
    select 1 from public.vora_commission_runs
    where business_id=o.business_id and order_id=o.id and status='completed'
  ) then
    update public.vora_inventory_reservations
      set status='consumed',updated_at=now()
      where order_id=o.id and status='reserved';

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
    set status='completed',
        completed_at=now(),
        qualified_amount=v_qualified,
        pv=v_pv,
        cv=v_cv
    where id=o.id;

  -- Reservation is now consumed and can never be released back to stock.
  update public.vora_inventory_reservations
    set status='consumed',updated_at=now()
    where order_id=o.id and status='reserved';

  insert into public.vora_commission_runs(
    business_id,order_id,status,started_at
  )
  values(o.business_id,o.id,'processing',now())
  on conflict(business_id,order_id)
  do update set status='processing',started_at=now(),error_message=null;

  if o.seller_member_id is not null then
    for r in
      select * from public.vora_commission_rules
      where business_id=o.business_id
        and active=true
        and rule_type='direct_sales'
        and (starts_at is null or starts_at<=now())
        and (ends_at is null or ends_at>=now())
      order by id
    loop
      v_commission:=(v_qualified*r.rate/100)+r.fixed_amount;
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
    if v_ancestor = any(v_visited) then
      raise exception 'sponsor cycle detected';
    end if;
    v_visited:=array_append(v_visited,v_ancestor);

    select sponsor_member_id into v_ancestor
    from public.vora_members
    where id=v_ancestor and business_id=o.business_id;

    exit when v_ancestor is null;

    for r in
      select * from public.vora_commission_rules
      where business_id=o.business_id
        and active=true
        and rule_type='unilevel'
        and level=v_level
        and (starts_at is null or starts_at<=now())
        and (ends_at is null or ends_at>=now())
    loop
      v_commission:=(v_qualified*r.rate/100)+r.fixed_amount;

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
    where business_id=o.business_id
      and member_id=r.member_id
      and currency='IDR'
    for update;

    insert into public.vora_wallet_transactions(
      wallet_id,business_id,member_id,direction,transaction_type,amount,
      balance_after,source_type,source_id,idempotency_key,description
    )
    values(
      v_wallet_id,o.business_id,r.member_id,'credit','commission',r.amount,
      v_balance+r.amount,'commission',r.id,
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
    set status='completed',
        total_commission=v_total_commission,
        completed_at=now()
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
      'commission',v_total_commission,
      'reservations_consumed',true
    )
  );

  return jsonb_build_object(
    'order_id',o.id,
    'status','completed',
    'qualified_amount',v_qualified,
    'pv',v_pv,
    'cv',v_cv,
    'commission',v_total_commission
  );

exception when others then
  update public.vora_commission_runs
    set status='failed',
        error_message=sqlerrm,
        completed_at=now()
    where business_id=o.business_id and order_id=o.id;
  raise;
end $$;

revoke all on function public.vora_complete_order(uuid) from public;
grant execute on function public.vora_complete_order(uuid) to authenticated;

-- 4. Withdrawal reversal must create a compensating wallet ledger entry.
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
declare
  w record;
  v_balance numeric;
begin
  select * into w
  from public.vora_withdrawals
  where id=p_withdrawal_id
  for update;

  if not found then raise exception 'withdrawal not found'; end if;
  if not public.vora_is_admin(w.business_id) then raise exception 'admin required'; end if;

  if p_status not in ('approved','processing','paid','rejected','cancelled') then
    raise exception 'invalid withdrawal status';
  end if;

  if w.status in ('paid','rejected','cancelled') then
    raise exception 'withdrawal is terminal';
  end if;

  if p_status='approved' and w.status<>'pending' then
    raise exception 'invalid transition';
  end if;

  if p_status='processing' and w.status not in ('pending','approved') then
    raise exception 'invalid transition';
  end if;

  if p_status='paid' and w.status not in ('processing','approved') then
    raise exception 'invalid transition';
  end if;

  if p_status in ('rejected','cancelled') and w.status not in ('pending','approved') then
    raise exception 'invalid transition';
  end if;

  if p_status='paid' then
    update public.vora_wallets
      set pending_balance=greatest(0,pending_balance-w.amount),
          updated_at=now()
      where id=w.wallet_id;

  elsif p_status in ('rejected','cancelled') then
    select available_balance into v_balance
    from public.vora_wallets
    where id=w.wallet_id
    for update;

    update public.vora_wallets
      set available_balance=available_balance+w.amount,
          pending_balance=greatest(0,pending_balance-w.amount),
          updated_at=now()
      where id=w.wallet_id;

    insert into public.vora_wallet_transactions(
      wallet_id,business_id,member_id,direction,transaction_type,amount,
      balance_after,source_type,source_id,idempotency_key,description
    )
    values(
      w.wallet_id,w.business_id,w.member_id,'credit','withdrawal_reversal',
      w.amount,v_balance+w.amount,'withdrawal',w.id,
      'withdrawal-reversal:'||w.id,
      'Withdrawal hold released after rejection/cancellation'
    )
    on conflict(wallet_id,idempotency_key) do nothing;
  end if;

  update public.vora_withdrawals
    set status=p_status,
        fee=coalesce(p_fee,fee),
        net_amount=greatest(0,amount-coalesce(p_fee,fee)),
        processed_at=case
          when p_status in ('paid','rejected','cancelled') then now()
          else processed_at
        end
    where id=w.id;

  insert into public.vora_audit_logs(
    business_id,actor_user_id,action,entity,entity_id,after_data
  )
  values(
    w.business_id,auth.uid(),'withdrawal.status_changed','vora_withdrawals',w.id,
    jsonb_build_object(
      'from',w.status,
      'to',p_status,
      'fee',coalesce(p_fee,w.fee)
    )
  );

  return true;
end $$;

revoke all on function public.vora_update_withdrawal_status(uuid,text,numeric) from public;
grant execute on function public.vora_update_withdrawal_status(uuid,text,numeric) to authenticated;

-- 5. Reconciliation now checks pending wallet exposure against active withdrawal holds.
create or replace function public.vora_financial_reconciliation(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_run uuid;
  v_orders int:=0;
  v_payments int:=0;
  v_refunds int:=0;
  v_wallets int:=0;
  v_ex int:=0;
  v_payment_ex jsonb:='[]'::jsonb;
  v_refund_ex jsonb:='[]'::jsonb;
  v_wallet_ex jsonb:='[]'::jsonb;
  x record;
begin
  if not public.vora_is_admin(p_business_id)
     and coalesce(auth.role(),'')<>'service_role' then
    raise exception 'admin required';
  end if;

  insert into public.vora_financial_reconciliation_runs(
    business_id,status,started_at
  )
  values(p_business_id,'completed',now())
  returning id into v_run;

  select count(*) into v_orders from public.vora_orders where business_id=p_business_id;
  select count(*) into v_payments from public.vora_payment_transactions where business_id=p_business_id;
  select count(*) into v_refunds from public.vora_refunds where business_id=p_business_id;
  select count(*) into v_wallets from public.vora_wallets where business_id=p_business_id;

  for x in
    select p.id,p.order_id,p.amount,o.status order_status,p.status payment_status
    from public.vora_payment_transactions p
    join public.vora_orders o on o.id=p.order_id
    where p.business_id=p_business_id
      and p.status='paid'
      and o.status in('pending','cancelled')
  loop
    v_ex:=v_ex+1;
    v_payment_ex:=v_payment_ex||jsonb_build_array(
      jsonb_build_object(
        'type','payment_order_mismatch',
        'payment_id',x.id,
        'order_id',x.order_id,
        'payment_status',x.payment_status,
        'order_status',x.order_status
      )
    );
  end loop;

  for x in
    select f.id,f.order_id,f.amount,f.status
    from public.vora_refunds f
    join public.vora_orders o on o.id=f.order_id
    where f.business_id=p_business_id
      and f.status='completed'
      and not exists(
        select 1
        from public.vora_payment_transactions p
        where p.id=f.payment_transaction_id
          and p.status in('refunded','partially_refunded')
      )
  loop
    v_ex:=v_ex+1;
    v_refund_ex:=v_refund_ex||jsonb_build_array(
      jsonb_build_object(
        'type','refund_payment_mismatch',
        'refund_id',x.id,
        'order_id',x.order_id,
        'amount',x.amount
      )
    );
  end loop;

  for x in
    select
      w.id,
      w.member_id,
      w.available_balance,
      w.pending_balance,
      coalesce((
        select sum(
          case when direction='credit' then amount else -amount end
        )
        from public.vora_wallet_transactions t
        where t.wallet_id=w.id
      ),0) ledger_available,
      coalesce((
        select sum(amount)
        from public.vora_withdrawals wd
        where wd.wallet_id=w.id
          and wd.status in('pending','approved','processing')
      ),0) expected_pending
    from public.vora_wallets w
    where w.business_id=p_business_id
  loop
    if round(x.available_balance,2)<>round(x.ledger_available,2)
       or round(x.pending_balance,2)<>round(x.expected_pending,2) then
      v_ex:=v_ex+1;
      v_wallet_ex:=v_wallet_ex||jsonb_build_array(
        jsonb_build_object(
          'type','wallet_balance_mismatch',
          'wallet_id',x.id,
          'member_id',x.member_id,
          'available_balance',x.available_balance,
          'ledger_available',x.ledger_available,
          'pending_balance',x.pending_balance,
          'expected_pending',x.expected_pending
        )
      );
    end if;
  end loop;

  update public.vora_financial_reconciliation_runs
    set orders_checked=v_orders,
        payments_checked=v_payments,
        refunds_checked=v_refunds,
        wallet_members_checked=v_wallets,
        exception_count=v_ex,
        report=jsonb_build_object(
          'payment_exceptions',v_payment_ex,
          'refund_exceptions',v_refund_ex,
          'wallet_exceptions',v_wallet_ex
        ),
        completed_at=now()
    where id=v_run;

  return jsonb_build_object(
    'run_id',v_run,
    'status','completed',
    'exception_count',v_ex,
    'orders_checked',v_orders,
    'payments_checked',v_payments,
    'refunds_checked',v_refunds,
    'wallet_members_checked',v_wallets,
    'payment_exceptions',v_payment_ex,
    'refund_exceptions',v_refund_ex,
    'wallet_exceptions',v_wallet_ex
  );

exception when others then
  if v_run is not null then
    update public.vora_financial_reconciliation_runs
      set status='failed',
          exception_count=v_ex,
          completed_at=now(),
          report=jsonb_build_object('error',sqlerrm)
      where id=v_run;
  end if;
  raise;
end $$;

revoke all on function public.vora_financial_reconciliation(uuid) from public;
grant execute on function public.vora_financial_reconciliation(uuid) to authenticated;

-- 6. Ensure all sensitive functions have explicit anon/public denial.
revoke execute on function public.vora_create_order(uuid,uuid,text,jsonb) from anon,public,authenticated;
revoke execute on function public.vora_settle_commission(uuid) from anon,public,authenticated;
revoke execute on function public.vora_release_order_reservation(uuid) from anon,public,authenticated;
revoke execute on function public.vora_release_expired_reservations(integer) from anon,public,authenticated;
revoke execute on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text) from anon,public;
revoke execute on function public.vora_complete_order(uuid) from anon,public;
revoke execute on function public.vora_request_withdrawal(uuid,numeric,jsonb,text) from anon,public;
revoke execute on function public.vora_update_withdrawal_status(uuid,text,numeric) from anon,public;
revoke execute on function public.vora_update_order_status(uuid,text) from anon,public;
revoke execute on function public.vora_refund_order(uuid,numeric,text,text) from anon,public;
revoke execute on function public.vora_update_refund_status(uuid,text) from anon,public;
revoke execute on function public.vora_mark_refund_processing(uuid,text,text) from anon,public;
revoke execute on function public.vora_settle_refund(uuid,text,text,text,text) from anon,public;
revoke execute on function public.vora_record_payment_webhook(uuid,text,text,text,boolean,jsonb) from anon,public;
revoke execute on function public.vora_financial_reconciliation(uuid) from anon,public;
