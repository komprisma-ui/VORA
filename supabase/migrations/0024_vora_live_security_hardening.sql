-- VORA live security hardening
drop policy if exists commission_rules_select on public.vora_commission_rules;
create policy commission_rules_select on public.vora_commission_rules for select to authenticated using (public.vora_is_member(business_id));
drop policy if exists commission_rules_admin on public.vora_commission_rules;
create policy commission_rules_admin on public.vora_commission_rules for all to authenticated using (public.vora_is_admin(business_id)) with check (public.vora_is_admin(business_id));
drop policy if exists commission_ledger_select on public.vora_commission_ledger;
create policy commission_ledger_select on public.vora_commission_ledger for select to authenticated using (public.vora_is_member(business_id) and (public.vora_is_admin(business_id) or member_id in (select id from public.vora_members where user_id=auth.uid() and business_id=vora_commission_ledger.business_id)));
drop policy if exists commission_runs_select on public.vora_commission_runs;
create policy commission_runs_select on public.vora_commission_runs for select to authenticated using (public.vora_is_admin(business_id));

revoke all on function public.vora_business_intelligence(uuid) from public, anon, authenticated;
revoke all on function public.vora_calculate_trust_score(uuid) from public, anon, authenticated;
revoke all on function public.vora_complete_order(uuid) from public, anon, authenticated;
revoke all on function public.vora_create_order_from_cart(uuid,text) from public, anon;
revoke all on function public.vora_executive_kpis(uuid) from public, anon, authenticated;
revoke all on function public.vora_financial_reconciliation(uuid) from public, anon, authenticated;
revoke all on function public.vora_is_admin(uuid) from public, anon;
revoke all on function public.vora_is_member(uuid) from public, anon;
revoke all on function public.vora_mark_refund_processing(uuid,text,text) from public, anon, authenticated;
revoke all on function public.vora_network_summary(uuid,uuid) from public, anon;
revoke all on function public.vora_record_payment(uuid,uuid,text,numeric,text,text,text) from public, anon, authenticated;
revoke all on function public.vora_record_payment_webhook(uuid,text,text,text,boolean,jsonb) from public, anon, authenticated;
revoke all on function public.vora_refund_order(uuid,numeric,text,text) from public, anon, authenticated;
revoke all on function public.vora_request_withdrawal(uuid,numeric,jsonb,text) from public, anon;
revoke all on function public.vora_resolve_risk_event(uuid,text) from public, anon, authenticated;
revoke all on function public.vora_settle_refund(uuid,text,text,text,text) from public, anon, authenticated;
revoke all on function public.vora_update_order_status(uuid,text) from public, anon, authenticated;
revoke all on function public.vora_update_refund_status(uuid,text) from public, anon, authenticated;
revoke all on function public.vora_update_withdrawal_status(uuid,text,numeric) from public, anon, authenticated;

grant execute on function public.vora_is_admin(uuid) to authenticated;
grant execute on function public.vora_is_member(uuid) to authenticated;
grant execute on function public.vora_network_summary(uuid,uuid) to authenticated;
grant execute on function public.vora_create_order_from_cart(uuid,text) to authenticated;
grant execute on function public.vora_request_withdrawal(uuid,numeric,jsonb,text) to authenticated;