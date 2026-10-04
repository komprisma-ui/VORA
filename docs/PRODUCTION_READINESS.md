# VORA Production Readiness Gate

## Current verified state
- GitHub Actions CI is green on the latest commit.
- Frontend production build is covered by CI.
- Financial/order/payment/refund RPC hardening is present in the migration chain.
- Payment and refund webhook Edge Functions are configured for provider callbacks with JWT disabled and provider signature validation performed in application code.

## Mandatory production gates

### 1. Supabase database
Apply migrations in filename order to the target Supabase project.

Before applying the latest hardening migration, run these preflight checks:

```sql
-- Provider references must be unique before the unique indexes are created.
select business_id, provider, provider_reference, count(*)
from vora_payment_transactions
where provider_reference is not null
group by business_id, provider, provider_reference
having count(*) > 1;

select business_id, provider_reference, count(*)
from vora_refunds
where provider_reference is not null
group by business_id, provider_reference
having count(*) > 1;
```

Both queries must return zero rows.

After migration, verify the sensitive RPC surface and execution privileges. Legacy client-facing financial mutation RPCs must remain revoked; sensitive mutations must be reachable only through the intended authenticated/admin/service-role path.

### 2. Payment provider sandbox
Run a complete sandbox cycle:
1. Create cart.
2. Checkout with an idempotency key.
3. Receive provider payment notification.
4. Verify payment amount and signature.
5. Confirm order becomes paid.
6. Complete order.
7. Verify PV/CV/qualified sales.
8. Verify direct/unilevel commission.
9. Verify wallet ledger and balance.
10. Request withdrawal.
11. Process withdrawal through each supported state.
12. Perform partial refund.
13. Process provider refund confirmation.
14. Verify commission reversal.
15. Perform full refund where appropriate.
16. Run financial reconciliation.

Repeat payment and refund notifications to confirm idempotency.

### 3. Operational controls
Configure Supabase Edge Function secrets, the correct Midtrans environment/server key, provider webhook URLs, a scheduler/cron for expired reservations, monitoring for failed commission runs/webhooks/reconciliation exceptions, and production backups/rollback.

### 4. Release rule
Do not market the platform as production-live until the database migration and sandbox end-to-end financial cycle have both passed.

CI success proves the repository builds; it does not prove that a particular Supabase project has received the migrations or that a payment provider has delivered a real webhook.

## Release evidence
Record the Git commit SHA, CI run number/conclusion, Supabase migration version, payment provider environment, sandbox payment reference, sandbox refund reference, reconciliation result, and operator/date for every release.