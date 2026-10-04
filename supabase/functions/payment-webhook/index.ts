import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const midtransServerKey = Deno.env.get("MIDTRANS_SERVER_KEY");

const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

async function sha512(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-512", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifyMidtrans(body: Record<string, unknown>) {
  if (!midtransServerKey) return false;
  const input = String(body.order_id ?? "") + String(body.status_code ?? "") +
    String(body.gross_amount ?? "") + midtransServerKey;
  const expected = await sha512(input);
  return safeEqual(expected, String(body.signature_key ?? ""));
}

function mapStatus(status: string) {
  switch (status) {
    case "settlement":
    case "capture":
      return "paid";
    case "pending":
      return "pending";
    case "expire":
      return "expired";
    case "deny":
    case "cancel":
    case "failure":
      return "failed";
    default:
      return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  try {
    const body = await req.json() as Record<string, unknown>;
    const provider = "midtrans";
    const verified = await verifyMidtrans(body);
    if (!verified) return Response.json({ ok: false, error: "invalid signature" }, { status: 401 });

    const orderNo = String(body.order_id ?? "");
    const providerEventId = String(body.transaction_id ?? \${orderNo} + ":" + String(body.transaction_status ?? "") + ":" + String(body.status_code ?? ""));
    const eventType = String(body.transaction_status ?? "unknown");
    const amount = Number(body.gross_amount);
    const mapped = mapStatus(eventType);
    if (!orderNo || !Number.isFinite(amount) || !mapped) {
      return Response.json({ ok: false, error: "unsupported notification" }, { status: 400 });
    }

    const { data: order, error: orderError } = await db
      .from("vora_orders")
      .select("id,business_id,total")
      .eq("order_no", orderNo)
      .maybeSingle();
    if (orderError || !order) return Response.json({ ok: false, error: "order not found" }, { status: 404 });

    const { data: eventId, error: eventError } = await db.rpc("vora_record_payment_webhook", {
      p_business_id: order.business_id,
      p_provider: provider,
      p_provider_event_id: providerEventId,
      p_event_type: eventType,
      p_signature_verified: true,
      p_payload: body,
    });
    if (eventError) throw eventError;

    const { data: paymentId, error: paymentError } = await db.rpc("vora_record_payment", {
      p_business_id: order.business_id,
      p_order_id: order.id,
      p_provider: provider,
      p_amount: amount,
      p_status: mapped,
      p_provider_reference: String(body.transaction_id ?? ""),
      p_idempotency_key: \${"webhook:"} + provider + ":" + providerEventId,
    });
    if (paymentError) throw paymentError;

    await db.from("vora_payment_webhook_events")
      .update({ status: "processed", processed_at: new Date().toISOString(), error_message: null })
      .eq("id", eventId);

    return Response.json({ ok: true, event_id: eventId, payment_id: paymentId });
  } catch (error) {
    return Response.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
});
