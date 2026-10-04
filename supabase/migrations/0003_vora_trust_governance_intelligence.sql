-- VORA Trust, Governance, Risk & Business Intelligence foundation
create table if not exists public.vora_business_profiles(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade unique,
 legal_name text,
 entity_type text,
 registration_number text,
 tax_id text,
 address jsonb not null default '{}'::jsonb,
 website text,
 industry text,
 founded_at date,
 description text,
 verification_status text not null default 'unverified' check(verification_status in('unverified','pending','verified','rejected','suspended')),
 trust_score numeric(5,2) not null default 0 check(trust_score between 0 and 100),
 updated_at timestamptz not null default now()
);

create table if not exists public.vora_kyc_profiles(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid not null references public.vora_members(id) on delete cascade unique,
 identity_type text not null default 'individual',
 verification_status text not null default 'pending' check(verification_status in('pending','review','verified','rejected','expired','blocked')),
 risk_level text not null default 'low' check(risk_level in('low','medium','high','critical')),
 document_type text,
 document_last4 text,
 verified_at timestamptz,
 expires_at date,
 reviewer_user_id uuid references auth.users(id) on delete set null,
 review_notes text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.vora_beneficial_owners(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 full_name text not null,
 ownership_percent numeric(7,4) not null check(ownership_percent between 0 and 100),
 identity_reference text,
 verification_status text not null default 'pending' check(verification_status in('pending','verified','rejected')),
 created_at timestamptz not null default now()
);

create table if not exists public.vora_risk_scores(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid references public.vora_members(id) on delete cascade,
 score numeric(6,2) not null check(score between 0 and 100),
 risk_level text not null check(risk_level in('low','medium','high','critical')),
 factors jsonb not null default '{}'::jsonb,
 model_version text not null default 'vora-risk-1',
 calculated_at timestamptz not null default now()
);

create table if not exists public.vora_risk_events(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid references public.vora_members(id) on delete set null,
 event_type text not null,
 severity text not null check(severity in('info','warning','high','critical')),
 score_delta numeric(6,2) not null default 0,
 metadata jsonb not null default '{}'::jsonb,
 resolved boolean not null default false,
 resolved_by uuid references auth.users(id) on delete set null,
 resolved_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.vora_incidents(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 category text not null,
 severity text not null check(severity in('low','medium','high','critical')),
 title text not null,
 description text,
 status text not null default 'open' check(status in('open','investigating','resolved','closed')),
 assigned_to uuid references auth.users(id) on delete set null,
 resolution text,
 created_at timestamptz not null default now(),
 resolved_at timestamptz
);

create table if not exists public.vora_policy_acceptances(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid references public.vora_members(id) on delete cascade,
 policy_code text not null,
 policy_version text not null,
 accepted_at timestamptz not null default now(),
 ip_address inet,
 user_agent text,
 unique(business_id,member_id,policy_code,policy_version)
);

create table if not exists public.vora_partner_scores(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 partner_member_id uuid not null references public.vora_members(id) on delete cascade,
 fulfillment_score numeric(5,2) not null default 0 check(fulfillment_score between 0 and 100),
 service_score numeric(5,2) not null default 0 check(service_score between 0 and 100),
 reliability_score numeric(5,2) not null default 0 check(reliability_score between 0 and 100),
 dispute_score numeric(5,2) not null default 0 check(dispute_score between 0 and 100),
 overall_score numeric(5,2) not null default 0 check(overall_score between 0 and 100),
 review_count integer not null default 0 check(review_count>=0),
 updated_at timestamptz not null default now(),
 unique(business_id,partner_member_id)
);

create table if not exists public.vora_business_metrics_daily(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 metric_date date not null,
 gmv numeric(18,2) not null default 0,
 qualified_sales numeric(18,2) not null default 0,
 orders integer not null default 0,
 active_members integer not null default 0,
 new_members integer not null default 0,
 repeat_customers integer not null default 0,
 refunds numeric(18,2) not null default 0,
 commissions numeric(18,2) not null default 0,
 withdrawals numeric(18,2) not null default 0,
 unique(business_id,metric_date)
);

create table if not exists public.vora_growth_goals(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 goal_type text not null,
 target_value numeric(18,2) not null check(target_value>=0),
 current_value numeric(18,2) not null default 0,
 period_start date not null,
 period_end date not null,
 status text not null default 'active' check(status in('active','achieved','paused','cancelled')),
 created_at timestamptz not null default now()
);

create table if not exists public.vora_cashflow_snapshots(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 snapshot_date date not null,
 gross_sales numeric(18,2) not null default 0,
 refunds numeric(18,2) not null default 0,
 commissions numeric(18,2) not null default 0,
 withdrawals numeric(18,2) not null default 0,
 net_operating_cash numeric(18,2) not null default 0,
 unique(business_id,snapshot_date)
);

create table if not exists public.vora_system_events(
 id bigint generated always as identity primary key,
 business_id uuid references public.vora_businesses(id) on delete cascade,
 event_name text not null,
 actor_user_id uuid references auth.users(id) on delete set null,
 correlation_id uuid,
 payload jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create index if not exists idx_vora_risk_events_open on public.vora_risk_events(business_id,resolved,severity,created_at desc);
create index if not exists idx_vora_metrics_daily on public.vora_business_metrics_daily(business_id,metric_date desc);
create index if not exists idx_vora_system_events on public.vora_system_events(business_id,created_at desc);

alter table public.vora_business_profiles enable row level security;
alter table public.vora_kyc_profiles enable row level security;
alter table public.vora_beneficial_owners enable row level security;
alter table public.vora_risk_scores enable row level security;
alter table public.vora_risk_events enable row level security;
alter table public.vora_incidents enable row level security;
alter table public.vora_policy_acceptances enable row level security;
alter table public.vora_partner_scores enable row level security;
alter table public.vora_business_metrics_daily enable row level security;
alter table public.vora_growth_goals enable row level security;
alter table public.vora_cashflow_snapshots enable row level security;
alter table public.vora_system_events enable row level security;

create policy business_profiles_admin on public.vora_business_profiles for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy kyc_admin on public.vora_kyc_profiles for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy beneficial_owner_admin on public.vora_beneficial_owners for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy risk_scores_admin on public.vora_risk_scores for select to authenticated using(public.vora_is_admin(business_id));
create policy risk_events_admin on public.vora_risk_events for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy incidents_admin on public.vora_incidents for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy policy_acceptance_member on public.vora_policy_acceptances for select to authenticated using(public.vora_is_member(business_id));
create policy policy_acceptance_admin on public.vora_policy_acceptances for insert to authenticated with check(public.vora_is_member(business_id));
create policy partner_scores_member on public.vora_partner_scores for select to authenticated using(public.vora_is_member(business_id));
create policy partner_scores_admin on public.vora_partner_scores for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy metrics_admin on public.vora_business_metrics_daily for select to authenticated using(public.vora_is_admin(business_id));
create policy goals_admin on public.vora_growth_goals for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy cashflow_admin on public.vora_cashflow_snapshots for select to authenticated using(public.vora_is_admin(business_id));
create policy events_admin on public.vora_system_events for select to authenticated using(public.vora_is_admin(business_id));

create or replace function public.vora_calculate_trust_score(p_business_id uuid)
returns numeric
language plpgsql security definer set search_path=''
as $$
declare
 v_score numeric:=0;
 v_verified numeric:=0;
 v_kyc numeric:=0;
 v_incidents numeric:=0;
 v_refund numeric:=0;
 v_orders numeric:=0;
begin
 select case when verification_status='verified' then 30 else 0 end into v_verified from public.vora_business_profiles where business_id=p_business_id;
 select case when count(*)>0 then 25 else 0 end into v_kyc from public.vora_kyc_profiles where business_id=p_business_id and verification_status='verified';
 select least(20,count(*)*2) into v_incidents from public.vora_incidents where business_id=p_business_id and status in('open','investigating');
 select coalesce(sum(refunds),0),coalesce(sum(orders),0) into v_refund,v_orders from public.vora_business_metrics_daily where business_id=p_business_id;
 v_score:=least(100,greatest(0,45+coalesce(v_verified,0)+coalesce(v_kyc,0)-coalesce(v_incidents,0)-case when v_orders>0 then least(20,(v_refund/nullif(v_orders,0))*100/1000000) else 0 end));
 update public.vora_business_profiles set trust_score=v_score,updated_at=now() where business_id=p_business_id;
 return v_score;
end $$;

revoke all on function public.vora_calculate_trust_score(uuid) from public;
grant execute on function public.vora_calculate_trust_score(uuid) to authenticated;
