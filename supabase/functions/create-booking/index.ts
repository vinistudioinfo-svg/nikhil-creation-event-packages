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
      return Response.json({ error: "Origin not allowed" }, { status: 403 });
    }

    if (req.method !== "POST") {
      return Response.json({ error: "Method not allowed" }, { status: 405 });
    }

    let body: any;
    try {
      body = await req.json();
    } catch {
      return Response.json({ error: "Invalid JSON" }, { status: 400 });
    }

    const enquiryId = body?.enquiryId;
    const accessTokenHash = body?.accessTokenHash;
    const advancePercent = Number(body?.advancePercent ?? 50);

    if (!enquiryId || typeof accessTokenHash !== "string" || accessTokenHash.length < 32) {
      return Response.json({ error: "Booking authorization data is incomplete" }, { status: 400 });
    }

    try {
      const { data, error } = await ctx.supabaseAdmin.rpc("nc_create_booking", {
        p_enquiry_id: enquiryId,
        p_access_token_hash: accessTokenHash,
        p_advance_percent: Number.isFinite(advancePercent) ? advancePercent : 50,
      });

      if (error) {
        console.error("create-booking database error", error.message);
        return Response.json({ error: error.message }, { status: 400 });
      }

      return Response.json({ ok: true, ...data });
    } catch (err) {
      console.error("create-booking error", err);
      return Response.json({ error: "Unable to create booking" }, { status: 500 });
    }
  }),
};
