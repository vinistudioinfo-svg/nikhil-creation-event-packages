const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

import { withSupabase } from "npm:@supabase/server@1";

const ALLOWED_ORIGINS = new Set([
  "https://nikhil-creation-event-packages.vercel.app",
  "https://nikhilcreation.com",
  "https://www.nikhilcreation.com",
  "http://localhost:3000",
  "http://localhost:5173",
]);

export default {
  fetch: withSupabase({ auth: "none" }, async (req, ctx) => {
    const origin = req.headers.get("origin");
    if (origin && !ALLOWED_ORIGINS.has(origin)) {
      return new Response(JSON.stringify({ error: "Origin not allowed" }), { status: 403, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: CORS_HEADERS });
    }

    if (req.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    let body: any;
    try {
      body = await req.json();
    } catch {
      return new Response(JSON.stringify({ error: "Invalid JSON" }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    const enquiryId = body?.enquiryId;
    const accessTokenHash = body?.accessTokenHash;
    const advancePercent = Number(body?.advancePercent ?? 50);

    if (!enquiryId || typeof accessTokenHash !== "string" || accessTokenHash.length < 32) {
      return new Response(JSON.stringify({ error: "Booking authorization data is incomplete" }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }

    try {
      const { data, error } = await ctx.supabaseAdmin.rpc("nc_create_booking", {
        p_enquiry_id: enquiryId,
        p_access_token_hash: accessTokenHash,
        p_advance_percent: Number.isFinite(advancePercent) ? advancePercent : 50,
      });

      if (error) {
        console.error("create-booking database error", error.message);
        return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
      }

      return new Response(JSON.stringify({ ok: true, ...data }), { headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    } catch (err) {
      console.error("create-booking error", err);
      return new Response(JSON.stringify({ error: "Unable to create booking" }), { status: 500, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
    }
  }),
};
