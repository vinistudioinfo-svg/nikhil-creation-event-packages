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

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } });
}

export default {
  fetch: withSupabase({ auth: "none" }, async (req, ctx) => {
    const origin = req.headers.get("origin");
    if (origin && !ALLOWED_ORIGINS.has(origin)) {
      return response({ error: "Origin not allowed" }, 403);
    }

    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
    if (req.method !== "POST") return response({ error: "Method not allowed" }, 405);

    let payload: any;
    try {
      payload = await req.json();
    } catch {
      return response({ error: "Invalid JSON" }, 400);
    }

    const raw = JSON.stringify(payload);
    if (raw.length > 500_000) return response({ error: "Payload too large" }, 413);

    const tokenHash = payload?.accessTokenHash;
    if (typeof tokenHash !== "string" || tokenHash.length < 32) {
      return response({ error: "Missing access token" }, 400);
    }

    try {
      const { data, error } = await ctx.supabaseAdmin.rpc("nc_submit_enquiry", {
        payload,
      });

      if (error) {
        console.error("submit-enquiry database error", error.message);
        return response({ error: error.message }, 400);
      }

      return response({ ok: true, ...data });
    } catch (err) {
      console.error("submit-enquiry error", err);
      return response({ error: "Unable to save enquiry" }, 500);
    }
  }),
};
