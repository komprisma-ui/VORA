-- VORA 2.11 provider refund callback bridge

create or replace function public.vora_mark_refund_processing(
  p_refund_id uuid,
  p_provider text,
  p_provider_reference text
)
returns boolean
language plpgsql security definer set search_path=''
as $$
declare f record;
begin
  select * into f from public.vora_refunds where id=p_refund_id for update;
  if not found then raise exception 'refund not found'; end if;
  if coalesce(auth.role(),'')<>'service_role' and not public.vora_is_admin(f.business_id) then
    raise exception 'privileged refund processing required';
  end if;
  if f.status='processing' then return true; end if;
  if f.status<>'approved' then raise exception 'refund must be approved'; end if;
  update public.vora_refunds
    set status='processing',provider_reference=p_provider_reference
    where id=f.id;
  insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
    values(f.business_id,auth.uid(),'refund.processing','vora_refunds',f.id,
      jsonb_build_object('provider',p_provider,'provider_reference',p_provider_reference));
  return true;
end $$;

revoke all on function public.vora_mark_refund_processing(uuid,text,text) from public;
grant execute on function public.vora_mark_refund_processing(uuid,text,text) to service_role,authenticated;

-- Allow the verified provider worker to advance an approved refund.
create or replace function public.vora_update_refund_status(
  p_refund_id uuid,
  p_status text
)
returns boolean
language plpgsql security definer set search_path=''
as $$
declare f record;
begin
  select * into f from public.vora_refunds where id=p_refund_id for update;
  if not found then raise exception 'refund not found'; end if;
  if coalesce(auth.role(),'')<>'service_role' and not public.vora_is_admin(f.business_id) then raise exception 'admin required'; end if;
  if p_status not in ('approved','processing','rejected') then raise exception 'invalid refund status'; end if;
  if f.status in ('completed','rejected') then raise exception 'refund is terminal'; end if;
  if p_status='approved' and f.status<>'requested' then raise exception 'invalid transition'; end if;
  if p_status='processing' and f.status<>'approved' then raise exception 'invalid transition'; end if;
  if p_status='rejected' and f.status not in ('requested','approved') then raise exception 'invalid transition'; end if;
  update public.vora_refunds set status=p_status,
    processed_at=case when p_status='rejected' then now() else processed_at end
    where id=f.id;
  insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
    values(f.business_id,auth.uid(),'refund.status_changed','vora_refunds',f.id,
      jsonb_build_object('from',f.status,'to',p_status,'amount',f.amount));
  return true;
end $$;

revoke all on function public.vora_update_refund_status(uuid,text) from public;
grant execute on function public.vora_update_refund_status(uuid,text) to service_role,authenticated;
