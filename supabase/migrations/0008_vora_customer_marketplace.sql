-- VORA 2.3 Customer Marketplace foundation
create table if not exists public.vora_customer_profiles(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 user_id uuid references auth.users(id) on delete set null,
 full_name text not null,
 phone text,
 email text,
 default_address jsonb not null default '{}'::jsonb,
 marketing_opt_in boolean not null default false,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(business_id,user_id)
);
create table if not exists public.vora_carts(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 status text not null default 'active' check(status in('active','converted','abandoned')),
 currency text not null default 'IDR',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(business_id,user_id)
);
create table if not exists public.vora_cart_items(
 id uuid primary key default gen_random_uuid(),
 cart_id uuid not null references public.vora_carts(id) on delete cascade,
 product_id uuid not null references public.vora_products(id) on delete restrict,
 quantity numeric(18,3) not null check(quantity>0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(cart_id,product_id)
);
create table if not exists public.vora_inventory_reservations(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 order_id uuid not null references public.vora_orders(id) on delete cascade,
 product_id uuid not null references public.vora_products(id) on delete restrict,
 outlet_code text not null default 'MAIN',
 quantity numeric(18,3) not null check(quantity>0),
 status text not null default 'reserved' check(status in('reserved','consumed','released')),
 expires_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(order_id,product_id,outlet_code)
);
create table if not exists public.vora_payment_transactions(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 order_id uuid not null references public.vora_orders(id) on delete cascade,
 provider text not null,
 provider_reference text,
 status text not null default 'pending' check(status in('pending','authorized','paid','failed','expired','refunded','partially_refunded')),
 amount numeric(18,2) not null check(amount>=0),
 currency text not null default 'IDR',
 raw_response jsonb not null default '{}'::jsonb,
 idempotency_key text not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(business_id,idempotency_key)
);
create table if not exists public.vora_refunds(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.vora_businesses(id) on delete cascade,
 order_id uuid not null references public.vora_orders(id) on delete restrict,
 payment_transaction_id uuid references public.vora_payment_transactions(id) on delete set null,
 amount numeric(18,2) not null check(amount>0),
 reason text not null,
 status text not null default 'requested' check(status in('requested','approved','processing','completed','rejected')),
 idempotency_key text not null,
 requested_by uuid references auth.users(id) on delete set null,
 processed_at timestamptz,
 created_at timestamptz not null default now(),
 unique(business_id,idempotency_key)
);
create index if not exists idx_vora_cart_items_cart on public.vora_cart_items(cart_id);
create index if not exists idx_vora_reservations_order on public.vora_inventory_reservations(business_id,order_id,status);
create index if not exists idx_vora_reservations_expiry on public.vora_inventory_reservations(status,expires_at);
create index if not exists idx_vora_payments_order on public.vora_payment_transactions(business_id,order_id,created_at desc);
create index if not exists idx_vora_refunds_order on public.vora_refunds(business_id,order_id,created_at desc);

alter table public.vora_customer_profiles enable row level security;
alter table public.vora_carts enable row level security;
alter table public.vora_cart_items enable row level security;
alter table public.vora_inventory_reservations enable row level security;
alter table public.vora_payment_transactions enable row level security;
alter table public.vora_refunds enable row level security;

create policy vora_customer_profile_self on public.vora_customer_profiles for all to authenticated using(user_id=auth.uid() and public.vora_is_member(business_id)) with check(user_id=auth.uid() and public.vora_is_member(business_id));
create policy vora_carts_self on public.vora_carts for all to authenticated using(user_id=auth.uid() and public.vora_is_member(business_id)) with check(user_id=auth.uid() and public.vora_is_member(business_id));
create policy vora_cart_items_self on public.vora_cart_items for all to authenticated using(exists(select 1 from public.vora_carts c where c.id=cart_id and c.user_id=auth.uid() and public.vora_is_member(c.business_id))) with check(exists(select 1 from public.vora_carts c where c.id=cart_id and c.user_id=auth.uid() and public.vora_is_member(c.business_id)));
create policy vora_reservations_admin on public.vora_inventory_reservations for select to authenticated using(public.vora_is_admin(business_id));
create policy vora_payments_visible on public.vora_payment_transactions for select to authenticated using(public.vora_is_admin(business_id) or exists(select 1 from public.vora_orders o where o.id=order_id and o.customer_user_id=auth.uid()));
create policy vora_refunds_visible on public.vora_refunds for select to authenticated using(public.vora_is_admin(business_id) or exists(select 1 from public.vora_orders o where o.id=order_id and o.customer_user_id=auth.uid()));
