create extension if not exists pgcrypto;

create table if not exists public.vora_businesses(
 id uuid primary key default gen_random_uuid(),
 name text not null,
 slug text not null unique,
 status text not null default 'active' check(status in('active','suspended')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.vora_memberships(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null default 'member' check(role in('owner','manager','finance','staff','member')),
 status text not null default 'active' check(status in('active','suspended','pending')),
 created_at timestamptz not null default now(),
 unique(business_id,user_id)
);

create table if not exists public.vora_members(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 user_id uuid references auth.users(id) on delete set null,
 member_code text not null,
 full_name text not null,
 phone text,
 email text,
 sponsor_member_id uuid references public.vora_members(id) on delete set null,
 placement_parent_id uuid references public.vora_members(id) on delete set null,
 placement_side text check(placement_side in('left','right')),
 status text not null default 'active' check(status in('active','inactive','suspended','pending')),
 rank_code text not null default 'STARTER',
 joined_at timestamptz not null default now(),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(business_id,member_code)
);

create table if not exists public.vora_products(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 sku text not null,
 name text not null,
 description text,
 sell_price numeric(18,2) not null default 0 check(sell_price>=0),
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(business_id,sku)
);

create table if not exists public.vora_product_stocks(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 product_id uuid not null references public.vora_products(id) on delete cascade,
 outlet_code text not null default 'MAIN',
 quantity numeric(18,3) not null default 0 check(quantity>=0),
 updated_at timestamptz not null default now(),
 unique(business_id,product_id,outlet_code)
);

create table if not exists public.vora_product_qualification(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 product_id uuid not null references public.vora_products(id) on delete cascade,
 qualified_rate numeric(8,4) not null default 100 check(qualified_rate between 0 and 100),
 pv_per_unit numeric(18,4) not null default 0 check(pv_per_unit>=0),
 cv_per_unit numeric(18,4) not null default 0 check(cv_per_unit>=0),
 active boolean not null default true,
 unique(business_id,product_id)
);

create table if not exists public.vora_orders(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 order_no text not null,
 customer_user_id uuid references auth.users(id) on delete set null,
 customer_member_id uuid references public.vora_members(id) on delete set null,
 seller_member_id uuid references public.vora_members(id) on delete set null,
 status text not null default 'pending' check(status in('pending','paid','completed','cancelled','refunded')),
 subtotal numeric(18,2) not null default 0 check(subtotal>=0),
 discount numeric(18,2) not null default 0 check(discount>=0),
 tax numeric(18,2) not null default 0 check(tax>=0),
 shipping numeric(18,2) not null default 0 check(shipping>=0),
 total numeric(18,2) not null default 0 check(total>=0),
 qualified_amount numeric(18,2) not null default 0 check(qualified_amount>=0),
 pv numeric(18,2) not null default 0 check(pv>=0),
 cv numeric(18,2) not null default 0 check(cv>=0),
 idempotency_key text not null,
 paid_at timestamptz,
 completed_at timestamptz,
 created_at timestamptz not null default now(),
 unique(business_id,idempotency_key),
 unique(business_id,order_no)
);

create table if not exists public.vora_order_items(
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.vora_orders(id) on delete cascade,
 product_id uuid not null references public.vora_products(id) on delete restrict,
 quantity numeric(18,3) not null check(quantity>0),
 unit_price numeric(18,2) not null check(unit_price>=0),
 discount numeric(18,2) not null default 0 check(discount>=0),
 line_total numeric(18,2) not null check(line_total>=0),
 pv numeric(18,2) not null default 0,
 cv numeric(18,2) not null default 0,
 created_at timestamptz not null default now()
);

create table if not exists public.vora_commission_rules(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 code text not null,
 rule_type text not null check(rule_type in('direct_sales','unilevel','rank_bonus')),
 level integer,
 rate numeric(8,4) not null default 0 check(rate>=0),
 fixed_amount numeric(18,2) not null default 0 check(fixed_amount>=0),
 active boolean not null default true,
 starts_at timestamptz,
 ends_at timestamptz,
 unique(business_id,code)
);

create table if not exists public.vora_commission_ledger(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid not null references public.vora_members(id) on delete restrict,
 order_id uuid references public.vora_orders(id) on delete restrict,
 rule_id uuid references public.vora_commission_rules(id) on delete restrict,
 entry_type text not null check(entry_type in('credit','reversal')),
 amount numeric(18,2) not null,
 source_key text not null,
 related_entry_id uuid references public.vora_commission_ledger(id) on delete restrict,
 status text not null default 'posted' check(status in('posted','void')),
 description text,
 metadata jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(business_id,source_key)
);

create table if not exists public.vora_commission_runs(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 order_id uuid not null references public.vora_orders(id) on delete restrict,
 status text not null default 'processing' check(status in('processing','completed','failed')),
 total_commission numeric(18,2) not null default 0,
 error_message text,
 started_at timestamptz not null default now(),
 completed_at timestamptz,
 unique(business_id,order_id)
);

create table if not exists public.vora_wallets(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid not null references public.vora_members(id) on delete restrict,
 currency text not null default 'IDR',
 available_balance numeric(18,2) not null default 0 check(available_balance>=0),
 pending_balance numeric(18,2) not null default 0 check(pending_balance>=0),
 status text not null default 'active' check(status in('active','blocked')),
 updated_at timestamptz not null default now(),
 unique(business_id,member_id,currency)
);

create table if not exists public.vora_wallet_transactions(
 id uuid primary key default gen_random_uuid(),
 wallet_id uuid not null references public.vora_wallets(id) on delete restrict,
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid not null references public.vora_members(id) on delete restrict,
 direction text not null check(direction in('credit','debit')),
 transaction_type text not null,
 amount numeric(18,2) not null check(amount>0),
 balance_after numeric(18,2) not null check(balance_after>=0),
 source_type text,
 source_id uuid,
 idempotency_key text not null,
 description text,
 metadata jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(wallet_id,idempotency_key)
);

create table if not exists public.vora_withdrawals(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 member_id uuid not null references public.vora_members(id) on delete restrict,
 wallet_id uuid not null references public.vora_wallets(id) on delete restrict,
 amount numeric(18,2) not null check(amount>0),
 fee numeric(18,2) not null default 0 check(fee>=0),
 net_amount numeric(18,2) not null check(net_amount>=0),
 status text not null default 'pending' check(status in('pending','approved','processing','paid','rejected','cancelled')),
 destination jsonb not null default '{}'::jsonb,
 idempotency_key text not null,
 requested_at timestamptz not null default now(),
 processed_at timestamptz,
 unique(business_id,idempotency_key)
);

create table if not exists public.vora_audit_logs(
 id uuid primary key default gen_random_uuid(),
 business_id uuid references public.vora_businesses(id) on delete cascade,
 actor_user_id uuid references auth.users(id) on delete set null,
 action text not null,
 entity text not null,
 entity_id uuid,
 before_data jsonb,
 after_data jsonb,
 ip_address inet,
 user_agent text,
 created_at timestamptz not null default now()
);

create index if not exists idx_vora_members_sponsor on public.vora_members(business_id,sponsor_member_id);
create index if not exists idx_vora_members_placement on public.vora_members(business_id,placement_parent_id);
create index if not exists idx_vora_orders_member on public.vora_orders(business_id,seller_member_id,created_at desc);
create index if not exists idx_vora_ledger_member on public.vora_commission_ledger(business_id,member_id,created_at desc);
create index if not exists idx_vora_wallet_tx_member on public.vora_wallet_transactions(business_id,member_id,created_at desc);
create index if not exists idx_vora_audit_entity on public.vora_audit_logs(business_id,entity,entity_id,created_at desc);

create or replace function public.vora_is_admin(p_business_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$select exists(select 1 from public.vora_memberships where business_id=p_business_id and user_id=auth.uid() and status='active' and role in('owner','manager','finance'));$$;

create or replace function public.vora_is_member(p_business_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$select exists(select 1 from public.vora_memberships where business_id=p_business_id and user_id=auth.uid() and status='active');$$;

alter table public.vora_businesses enable row level security;
alter table public.vora_memberships enable row level security;
alter table public.vora_members enable row level security;
alter table public.vora_products enable row level security;
alter table public.vora_product_stocks enable row level security;
alter table public.vora_product_qualification enable row level security;
alter table public.vora_orders enable row level security;
alter table public.vora_order_items enable row level security;
alter table public.vora_commission_rules enable row level security;
alter table public.vora_commission_ledger enable row level security;
alter table public.vora_commission_runs enable row level security;
alter table public.vora_wallets enable row level security;
alter table public.vora_wallet_transactions enable row level security;
alter table public.vora_withdrawals enable row level security;
alter table public.vora_audit_logs enable row level security;

drop policy if exists business_select on public.vora_businesses;
create policy business_select on public.vora_businesses for select to authenticated using(public.vora_is_member(id));

drop policy if exists membership_select on public.vora_memberships;
create policy membership_select on public.vora_memberships for select to authenticated using(public.vora_is_member(business_id));

drop policy if exists members_select on public.vora_members;
create policy members_select on public.vora_members for select to authenticated using(public.vora_is_member(business_id));
drop policy if exists members_admin_write on public.vora_members;
create policy members_admin_write on public.vora_members for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));

drop policy if exists products_select on public.vora_products;
create policy products_select on public.vora_products for select to authenticated using(public.vora_is_member(business_id));
drop policy if exists products_admin_write on public.vora_products;
create policy products_admin_write on public.vora_products for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));

drop policy if exists stock_admin on public.vora_product_stocks;
create policy stock_admin on public.vora_product_stocks for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));

drop policy if exists qualification_select on public.vora_product_qualification;
create policy qualification_select on public.vora_product_qualification for select to authenticated using(public.vora_is_member(business_id));
drop policy if exists qualification_admin on public.vora_product_qualification;
create policy qualification_admin on public.vora_product_qualification for all to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));

drop policy if exists orders_select on public.vora_orders;
create policy orders_select on public.vora_orders for select to authenticated using(public.vora_is_member(business_id));

drop policy if exists items_select on public.vora_order_items;
create policy items_select on public.vora_order_items for select to authenticated using(exists(select 1 from public.vora_orders o where o.id=order_id and public.vora_is_member(o.business_id)));

drop policy if exists wallet_select on public.vora_wallets;
create policy wallet_select on public.vora_wallets for select to authenticated using(public.vora_is_member(business_id) and (public.vora_is_admin(business_id) or member_id in(select id from public.vora_members where user_id=auth.uid() and business_id=vora_wallets.business_id)));

drop policy if exists wallet_tx_select on public.vora_wallet_transactions;
create policy wallet_tx_select on public.vora_wallet_transactions for select to authenticated using(public.vora_is_member(business_id) and (public.vora_is_admin(business_id) or member_id in(select id from public.vora_members where user_id=auth.uid() and business_id=vora_wallet_transactions.business_id)));

drop policy if exists withdrawal_select on public.vora_withdrawals;
create policy withdrawal_select on public.vora_withdrawals for select to authenticated using(public.vora_is_member(business_id) and (public.vora_is_admin(business_id) or member_id in(select id from public.vora_members where user_id=auth.uid() and business_id=vora_withdrawals.business_id)));

drop policy if exists withdrawal_admin on public.vora_withdrawals;
create policy withdrawal_admin on public.vora_withdrawals for update to authenticated using(public.vora_is_admin(business_id)) with check(public.vora_is_admin(business_id));

drop policy if exists audit_select on public.vora_audit_logs;
create policy audit_select on public.vora_audit_logs for select to authenticated using(public.vora_is_admin(business_id));

revoke all on all tables in schema public from anon;
grant select on public.vora_businesses,public.vora_memberships,public.vora_members,public.vora_products,public.vora_product_qualification,public.vora_orders,public.vora_order_items,public.vora_wallets,public.vora_wallet_transactions,public.vora_withdrawals,public.vora_audit_logs to authenticated;
