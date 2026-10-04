# VORA Payment Webhooks & Financial Settlement

## Current provider adapter
VORA includes a verified **Midtrans** adapter.

### Required Supabase secrets
- `MIDTRANS_SERVER_KEY`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`

The service-role key is server-only and must never be shipped in the Android/web client.

## Endpoints
After deploying Supabase Edge Functions:
- `/functions/v1/payment-webhook`
- `/functions/v1/refund-webhook`

The endpoints intentionally disable Supabase JWT verification because the provider calls them directly. They verify the Midtrans signature before any financial RPC is executed.

## Payment flow
1. Midtrans sends the transaction notification.
2. VORA verifies SHA-512(`order_id + status_code + gross_amount + ServerKey`).
3. VORA records the provider event idempotently.
4. VORA records the payment idempotently.
5. A successful payment moves the order to `paid`.
6. Completion/commission settlement remains a privileged backend operation.

## Refund flow
1. Admin creates a refund request.
2. Admin approves it.
3. The provider refund reference is attached and the refund moves to `processing`.
4. Midtrans sends refund notifications.
5. VORA waits for `bank_confirmed_at` before treating the refund as settled.
6. VORA settles the refund exactly once.
7. Commission reversals are calculated against the commission actually posted for the order.
8. If a member wallet does not contain enough balance, the unrecovered amount becomes a tracked financial receivable instead of forcing a negative wallet.
9. The payment becomes `partially_refunded` or `refunded`; the order becomes `refunded` only when the full order amount has been refunded.

## Reconciliation
Run the privileged RPC:
`vora_financial_reconciliation(business_id)`

It checks:
- paid payment vs order state mismatches
- completed refund vs payment state mismatches
- wallet balance vs wallet transaction ledger
- exception count and machine-readable report

## Deployment
Apply migrations in order, deploy both Edge Functions, then configure the Midtrans notification URL to the payment webhook. Configure refund notifications to the refund webhook.

Do not mark the system production-ready until the migrations have been applied to the actual Supabase project and end-to-end sandbox payment/refund tests pass.
