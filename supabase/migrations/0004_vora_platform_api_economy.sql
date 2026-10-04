-- VORA platform / API economy layer
create table if not exists public.vora_api_clients(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 name text not null,
 client_id text not null unique,
 secret_hash text not null,
 status text not null default 'active' check(status in('active','revoked','suspended')),
 scopes text[] not null default '{}',
 last_used_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.vora_webhook_endpoints(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 url text not null,
 secret_hash text not null,
 events text[] not null default '{}',
 status text not null default 'active' check(status in('active','paused','failed')),
 failure_count integer not null default 0,
 last_success_at timestamptz,
 last_failure_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.vora_webhook_deliveries(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 endpoint_id uuid not null references public.vora_webhook_endpoints(id) on delete cascade,
 event_name text not null,
 event_id uuid not null,
 attempt integer not null default 1,
 status text not null default 'queued' check(status in('queued','delivered','failed')),
 response_code integer,
 response_ms integer,
 delivered_at timestamptz,
 next_attempt_at timestamptz,
 created_at timestamptz not null default now()
);

create table if not exists public.vora_subscriptions(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 plan_code text not null default 'growth',
 status text not null default 'active' check(status in('trial','active','past_due','cancelled')),
 monthly_fee numeric(18,2) not null default 0,
 currency text not null default 'IDR',
 started_at timestamptz not null default now(),
 renews_at date
);

create table if not exists public.vora_feature_flags(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 feature_code text not null,
 enabled boolean not null default false,
 config jsonb not null default '{}'::jsonb,
 unique(business_id,feature_code)
);

create table if not exists public.vora_integrations(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 provider text not null,
 category text not null,
 status text not null default 'connected' check(status in('connected','disconnected','error','pending')),
 external_account_ref text,
 last_sync_at timestamptz,
 metadata jsonb not null default '{}'::jsonb,
 unique(business_id,provider)
);

create table if not exists public.vora_business_reviews(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 reviewer_member_id uuid references public.vora_members(id) on delete set null,
 partner_member_id uuid references public.vora_members(id) on delete set null,
 order_id uuid references public.vora_orders(id) on delete set null,
 rating integer not null check(rating between 1 and 5),
 title text,
 review text,
 verified_purchase boolean not null default false,
 status text not null default 'published' check(status in('pending','published','hidden','flagged')),
 created_at timestamptz not null default now()
);

create table if not exists public.vora_customer_segments(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 name text not null,
 criteria jsonb not null default '{}'::jsonb,
 member_count integer not null default 0,
 estimated_value numeric(18,2) not null default 0,
 updated_at timestamptz not null default now()
);

alter table public.vora_api_clients enable row level security;
alter table public.vora_webhook_endpoints enable row level security;
alter table public.vora_webhook_deliveries enable row level security;
alter table public.vora_subscriptions enable row level security;
alter table public.vora_feature_flags enable row level security;
alter table public.vora_integrations enable row level security;
alter table public.vora_business_reviews enable row level security;
alter table public.vora_customer_segments enable row level security;

create policy api_clients_admin on public.vora_api_clients for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy webhooks_admin on public.vora_webhook_endpoints for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy webhook_delivery_admin on public.vora_webhook_deliveries for select to authenticated using(public.vora_is_admin(business_id));
create policy subscription_admin on public.vora_subscriptions for select to authenticated using(public.vora_is_admin(business_id));
create policy feature_flags_admin on public.vora_feature_flags for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy integrations_admin on public.vora_integrations for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy reviews_member on public.vora_business_reviews for select to authenticated using(public.vora_is_member(business_id));
create policy reviews_admin on public.vora_business_reviews for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));
create policy segments_admin on public.vora_customer_segments for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));

create index if not exists idx_vora_reviews_partner on public.vora_business_reviews(business_id,partner_member_id,status);
create index if not exists idx_vora_webhook_queue on public.vora_webhook_deliveries(status,next_attempt_at);

revoke all on public.vora_api_clients,public.vora_webhook_endpoints,public.vora_webhook_deliveries from anon;
