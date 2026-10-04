-- VORA 2.0: intelligence RPCs, network analytics, governance hardening and operational safety

create index if not exists idx_vora_orders_business_status_created
  on public.vora_orders(business_id,status,created_at desc);
create index if not exists idx_vora_members_business_status_created
  on public.vora_members(business_id,status,created_at desc);
create index if not exists idx_vora_wallets_business_balance
  on public.vora_wallets(business_id,available_balance desc);
create index if not exists idx_vora_commission_runs_business_status
  on public.vora_commission_runs(business_id,status,started_at desc);

-- Executive KPI snapshot. Read-only and scoped to the caller's business.
create or replace function public.vora_executive_kpis(p_business_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path=''
as $$
declare
 v jsonb;
begin
 if not public.vora_is_member(p_business_id) then raise exception 'not authorized'; end if;
 with o as (
   select
     count(*) filter(where status<>'cancelled') orders,
     coalesce(sum(total) filter(where status<>'cancelled'),0) gmv,
     coalesce(sum(qualified_amount) filter(where status not in('cancelled','refunded')),0) qualified_sales,
     count(distinct seller_member_id) filter(where status not in('cancelled','refunded')) active_sellers
   from public.vora_orders where business_id=p_business_id
 ),
 m as (
   select count(*) filter(where status='active') active_members,
          count(*) filter(where joined_at::date=current_date) new_members
   from public.vora_members where business_id=p_business_id
 ),
 w as (
   select coalesce(sum(available_balance),0) wallet_liability
   from public.vora_wallets where business_id=p_business_id and status='active'
 ),
 r as (
   select count(*) open_risks from public.vora_risk_events
   where business_id=p_business_id and resolved=false
 ),
 i as (
   select count(*) open_incidents from public.vora_incidents
   where business_id=p_business_id and status in('open','investigating')
 ),
 p as (
   select coalesce(trust_score,0) trust_score, verification_status
   from public.vora_business_profiles where business_id=p_business_id
 )
 select jsonb_build_object(
   'orders',o.orders,'gmv',o.gmv,'qualified_sales',o.qualified_sales,
   'active_sellers',o.active_sellers,'active_members',m.active_members,
   'new_members_today',m.new_members,'wallet_liability',w.wallet_liability,
   'open_risks',r.open_risks,'open_incidents',i.open_incidents,
   'trust_score',coalesce(p.trust_score,0),'verification_status',coalesce(p.verification_status,'unverified')
 ) into v
 from o,m,w,r,i left join p on true;
 return v;
end $$;

-- Network summary: depth, direct referrals and active descendants.
create or replace function public.vora_network_summary(p_business_id uuid,p_member_id uuid)
returns jsonb
language sql stable security definer
set search_path=''
as $$
with recursive tree as(
 select m.id,m.sponsor_member_id,0 depth,m.status
 from public.vora_members m
 where m.id=p_member_id and m.business_id=p_business_id
 union all
 select c.id,c.sponsor_member_id,t.depth+1,c.status
 from public.vora_members c join tree t on c.sponsor_member_id=t.id
 where c.business_id=p_business_id and t.depth<100
)
select jsonb_build_object(
 'root_member_id',p_member_id,
 'direct_referrals',(select count(*) from public.vora_members where business_id=p_business_id and sponsor_member_id=p_member_id),
 'total_descendants',(select greatest(count(*)-1,0) from tree),
 'active_descendants',(select count(*) from tree where depth>0 and status='active'),
 'max_depth',(select coalesce(max(depth),0) from tree)
)
where public.vora_is_member(p_business_id);
$$;

-- Controlled risk resolution. Every resolution leaves an immutable audit event.
create or replace function public.vora_resolve_risk_event(p_event_id uuid,p_resolution text)
returns boolean
language plpgsql security definer
set search_path=''
as $$
declare e record;
begin
 select * into e from public.vora_risk_events where id=p_event_id for update;
 if not found then raise exception 'risk event not found'; end if;
 if not public.vora_is_admin(e.business_id) then raise exception 'not authorized'; end if;
 update public.vora_risk_events
 set resolved=true,resolved_by=auth.uid(),resolved_at=now()
 where id=p_event_id;
 insert into public.vora_audit_logs(business_id,actor_user_id,action,entity,entity_id,after_data)
 values(e.business_id,auth.uid(),'risk.resolve','vora_risk_events',e.id,
        jsonb_build_object('resolution',coalesce(p_resolution,''),'resolved_at',now()));
 return true;
end $$;

-- Prevent direct mutation of financial ledgers by authenticated clients.
revoke insert,update,delete on public.vora_commission_ledger from authenticated;
revoke insert,update,delete on public.vora_wallet_transactions from authenticated;
revoke insert,update,delete on public.vora_commission_runs from authenticated;

-- Read-only access remains available through existing scoped policies.
grant select on public.vora_commission_ledger,public.vora_commission_runs to authenticated;

revoke all on function public.vora_executive_kpis(uuid) from public;
grant execute on function public.vora_executive_kpis(uuid) to authenticated;
revoke all on function public.vora_network_summary(uuid,uuid) from public;
grant execute on function public.vora_network_summary(uuid,uuid) to authenticated;
revoke all on function public.vora_resolve_risk_event(uuid,text) from public;
grant execute on function public.vora_resolve_risk_event(uuid,text) to authenticated;
