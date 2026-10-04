-- VORA order/payment/refund lifecycle
create or replace function public.vora_record_payment(p_business_id uuid,p_order_id uuid,p_provider text,p_amount numeric,p_status text,p_provider_reference text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare o record; pid uuid;
begin
 select * into o from public.vora_orders where id=p_order_id and business_id=p_business_id for update;
 if not found then raise exception 'order not found'; end if;
 if not public.vora_is_admin(p_business_id) and o.customer_user_id<>auth.uid() then raise exception 'not authorized'; end if;
 if p_amount<=0 or p_amount<>o.total then raise exception 'payment amount mismatch'; end if;
 select id into pid from public.vora_payment_transactions where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if pid is not null then return pid; end if;
 insert into public.vora_payment_transactions(business_id,order_id,provider,provider_reference,status,amount,idempotency_key) values(p_business_id,p_order_id,p_provider,p_provider_reference,p_status,p_amount,p_idempotency_key) returning id into pid;
 if p_status='paid' then update public.vora_orders set status='paid',paid_at=coalesce(paid_at,now()) where id=p_order_id; end if;
 insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data) values(p_business_id,auth.uid(),'payment.recorded','vora_orders',p_order_id,jsonb_build_object('payment_id',pid,'provider',p_provider,'status',p_status,'amount',p_amount));
 return pid;
end $$;

create or replace function public.vora_update_order_status(p_order_id uuid,p_status text)
returns boolean language plpgsql security definer set search_path=''
as $$
declare o record;
begin
 select * into o from public.vora_orders where id=p_order_id for update;
 if not found then raise exception 'order not found'; end if;
 if not public.vora_is_admin(o.business_id) then raise exception 'admin required'; end if;
 if p_status not in('pending','paid','processing','shipped','completed','cancelled','refunded') then raise exception 'invalid order status'; end if;
 if o.status='refunded' and p_status<>'refunded' then raise exception 'refunded order is terminal'; end if;
 update public.vora_orders set status=p_status,completed_at=case when p_status='completed' then coalesce(completed_at,now()) else completed_at end where id=p_order_id;
 if p_status='completed' then update public.vora_inventory_reservations set status='consumed',updated_at=now() where order_id=p_order_id and status='reserved'; end if;
 if p_status='cancelled' then perform public.vora_release_order_reservation(p_order_id); end if;
 insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data) values(o.business_id,auth.uid(),'order.status_changed','vora_orders',p_order_id,jsonb_build_object('from',o.status,'to',p_status));
 return true;
end $$;

revoke all on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text) from public;
revoke all on function public.vora_update_order_status(uuid,text) from public;
grant execute on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text),public.vora_update_order_status(uuid,text) to authenticated;
