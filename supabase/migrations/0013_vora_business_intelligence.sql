-- VORA 2.6 business intelligence engine

create or replace function public.vora_business_intelligence(p_biz_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare result jsonb;
begin
 if not public.vora_is_admin(p_biz_id) then raise exception 'not authorized'; end if;

 with
 orders as (
   select * from public.vora_orders where business_id=p_biz_id
 ),
 completed as (
   select * from orders where status='completed'
 ),
 products as (
   select p.id,p.sku,p.name,
     coalesce(sum(case when o.status='completed' then oi.quantity else 0 end),0) units,
     coalesce(sum(case when o.status='completed' then oi.line_total else 0 end),0) revenue
   from public.vora_products p
   left join public.vora_order_items oi on oi.product_id=p.id
   left join public.vora_orders o on o.id=oi.order_id and o.business_id=p_biz_id
   where p.business_id=p_biz_id
   group by p.id,p.sku,p.name
 ),
 partners as (
   select m.id,m.member_code,m.full_name,m.rank_code,
     coalesce(count(distinct o.id) filter(where o.status='completed'),0) orders,
     coalesce(sum(o.total) filter(where o.status='completed'),0) sales,
     coalesce(sum(cl.amount) filter(where cl.entry_type='credit' and cl.status='posted'),0) commissions
   from public.vora_members m
   left join public.vora_orders o on o.seller_member_id=m.id and o.business_id=p_biz_id
   left join public.vora_commission_ledger cl on cl.member_id=m.id and cl.business_id=p_biz_id
   where m.business_id=p_biz_id
   group by m.id,m.member_code,m.full_name,m.rank_code
 ),
 wallet as (
   select coalesce(sum(available_balance),0) available,
          coalesce(sum(pending_balance),0) pending
   from public.vora_wallets where business_id=p_biz_id
 ),
 risk as (
   select
     count(*) filter(where status in('pending','processing')) withdrawals_pending,
     coalesce(sum(amount) filter(where status in('pending','processing')),0) withdrawals_value
   from public.vora_withdrawals where business_id=p_biz_id
 ),
 customer as (
   select count(distinct customer_user_id) customers,
          count(distinct customer_user_id) filter(where customer_user_id is not null and customer_user_id in(
            select customer_user_id from orders group by customer_user_id having count(*)>1
          )) repeat_customers
   from completed
 )
 select jsonb_build_object(
   'generated_at',now(),
   'commerce',jsonb_build_object(
     'orders_total',(select count(*) from orders),
     'orders_completed',(select count(*) from completed),
     'revenue',(select coalesce(sum(total),0) from completed),
     'qualified_sales',(select coalesce(sum(qualified_amount),0) from completed),
     'pv',(select coalesce(sum(pv),0) from completed),
     'cv',(select coalesce(sum(cv),0) from completed),
     'average_order_value',(select coalesce(avg(total),0) from completed)
   ),
   'customers',jsonb_build_object(
     'unique_customers',(select customers from customer),
     'repeat_customers',(select repeat_customers from customer),
     'repeat_rate',case when (select customers from customer)>0 then round((select repeat_customers::numeric/(customers) from customer)*100,2) else 0 end
   ),
   'products',(select coalesce(jsonb_agg(to_jsonb(products) order by revenue desc),'[]'::jsonb) from products),
   'partners',(select coalesce(jsonb_agg(to_jsonb(partners) order by sales desc),'[]'::jsonb) from partners),
   'wallet',jsonb_build_object('available',(select available from wallet),'pending',(select pending from wallet)),
   'risk',jsonb_build_object('pending_withdrawals',(select withdrawals_pending from risk),'pending_withdrawal_value',(select withdrawals_value from risk)),
   'signals',jsonb_build_object(
     'commerce_health',case when (select count(*) from completed)>0 then 100 else 25 end,
     'customer_retention',case when (select customers from customer)>0 then least(100,round((select repeat_customers::numeric/customers from customer)*100,0)) else 25 end,
     'product_health',case when (select count(*) from products where units>0)>0 then 100 else 25 end,
     'financial_integrity',case when (select count(*) from public.vora_commission_runs where business_id=p_biz_id and status='failed')=0 then 100 else 50 end
   )
 ) into result;
 return result;
end $$;

revoke all on function public.vora_business_intelligence(uuid) from public;
grant execute on function public.vora_business_intelligence(uuid) to authenticated;
