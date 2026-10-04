import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const serverKey = Deno.env.get("MIDTRANS_SERVER_KEY");
const db = createClient(url, key, { auth: { persistSession: false } });

async function sha512(value: string) {
  const digest = await crypto.subtle.digest("SHA-512", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function equal(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  try {
    if (!serverKey) return Response.json({ ok: false, error: "MIDTRANS_SERVER_KEY is not configured" }, { status: 500 });
    const body = await req.json() as Record<string, unknown>;
    const input = String(body.order_id ?? "") + String(body.status_code ?? "") +
      String(body.gross_amount ?? "") + serverKey;
    if (!equal(await sha512(input), String(body.signature_key ?? ""))) {
      return Response.json({ ok: false, error: "invalid signature" }, { status: 401 });
    }

    const status = String(body.transaction_status ?? "");
    if (status !== "refund" && status !== "partial_refund") {
      return Response.json({ ok: true, ignored: true });
    }

    // Midtrans sends a second refund notification after bank confirmation.
    // Only that confirmed notification is allowed to settle the refund.
    if (!body.bank_confirmed_at) {
      return Response.json({ ok: true, accepted: true, pending_bank_confirmation: true });
    }

    const orderNo = String(body.order_id ?? "");
    const refundKey = String(body.refund_key ?? "");
    if (!orderNo || !refundKey) {
      return Response.json({ ok: false, error: "missing order_id/refund_key" }, { status: 400 });
    }

    const { data: order, error: orderError } = await db
      .from("vora_orders").select("id,business_id").eq("order_no", orderNo).maybeSingle();
    if (orderError || !order) return Response.json({ ok: false, error: "order not found" }, { status: 404 });

    const { data: refund, error: refundError } = await db
      .from("vora_refunds")
      .select("id,status,amount,provider_reference")
      .eq("business_id", order.business_id)
      .eq("order_id", order.id)
      .eq("provider_reference", refundKey)
      .maybeSingle();
    if (refundError || !refund) {
      return Response.json({ ok: false, error: "refund reference not found" }, { status: 404 });
    }
    if (refund.status !== "processing") {
      return Response.json({ ok: true, ignored: true, status: refund.status });
    }

    const eventId = "midtrans-refund:" + String(body.refund_chargeback_id ?? refundKey);
    const { data: recorded, error: recordError } = await db.rpc("vora_record_payment_webhook", {
      p_business_id: order.business_id,
      p_provider: "midtrans",
      p_provider_event_id: eventId,
      p_event_type: status,
      p_signature_verified: true,
      p_payload: body,
    });
    if (recordError) throw recordError;

    const { data: settled, error: settleError } = await db.rpc("vora_settle_refund", {
      p_refund_id: refund.id,
      p_provider: "midtrans",
      p_provider_reference: refundKey,
      p_provider_event_id: eventId,
      p_idempotency_key: "refund-settlement:" + eventId,
    });
    if (settleError) throw settleError;

    await db.from("vora_payment_webhook_events")
      .update({ status: "processed", processed_at: new Date().toISOString(), error_message: null })
      .eq("id", recorded);

    return Response.json({ ok: true, refund: settled });
  } catch (error) {
    return Response.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
});
