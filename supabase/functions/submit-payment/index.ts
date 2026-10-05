import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok:false, error:"Method not allowed" },405);

  try {
    const body = await req.json();
    const bookingId = body?.bookingId;
    const accessTokenHash = body?.accessTokenHash;
    const amountPaid = Number(body?.amountPaid);
    const utr = String(body?.utr ?? "").trim();

    if (!bookingId || typeof accessTokenHash !== "string" || accessTokenHash.length < 32) {
      return json({ ok:false, error:"Booking authorization data is incomplete" },400);
    }
    if (!Number.isFinite(amountPaid) || amountPaid < 0) {
      return json({ ok:false, error:"Invalid payment amount" },400);
    }
    if (utr.length < 3) return json({ ok:false, error:"UTR / transaction ID is required" },400);

    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) return json({ ok:false, error:"Supabase server configuration is missing" },500);

    const supabase = createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
    const { data, error } = await supabase.rpc("nc_submit_payment", {
      p_booking_id: bookingId,
      p_access_token_hash: accessTokenHash,
      p_amount_paid: amountPaid,
      p_utr: utr,
    });

    if (error) {
      console.error("nc_submit_payment error:", error);
      return json({ ok:false, error:error.message },400);
    }

    return json({ ok:true, ...(data ?? {}) });
  } catch (error) {
    console.error("submit-payment error:",error);
    return json({ ok:false, error:error instanceof Error ? error.message : "Unexpected server error" },500);
  }
});
