// TV<->phone device pairing. RLS lets clients insert ONLY a pending
// tv_pairings row (the TV does that directly, with its own tv_secret) — every
// read/update of that row goes through here via the service-role client.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

Deno.serve(async (req) => {
  try {
    const body = await req.json();

    if (body.action === "info") {
      const { data } = await admin.from("tv_pairings")
        .select("device_name,expires_at")
        .eq("code", body.code).eq("status", "pending").maybeSingle();
      if (!data || data.expires_at < Date.now()) return json({ ok: false, error: "not_found" }, 404);
      return json({ ok: true, deviceName: data.device_name });
    }

    if (body.action === "approve") {
      // Phone must be signed in — this is what proves who is granting access.
      const authz = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
      const { data: userRes } = await admin.auth.getUser(authz);
      const user = userRes?.user;
      if (!user) return json({ ok: false, error: "unauthorized" }, 401);

      const { data: row } = await admin.from("tv_pairings")
        .select("id,expires_at")
        .eq("code", body.code).eq("status", "pending").maybeSingle();
      if (!row || row.expires_at < Date.now()) return json({ ok: false, error: "expired" }, 410);

      // One-time login for the TV to become this user with, handed back only
      // via poll() and gated there by tv_secret (see below).
      const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
        type: "magiclink",
        email: user.email!,
      });
      if (linkErr) return json({ ok: false, error: "server_error" }, 500);

      // Hand back the hashed_token (not the 6-digit email_otp): the TV is signed
      // OUT and has no email, so it must verify via verifyOtp({ tokenHash }) which
      // needs no email. The email_otp would require the address we don't send.
      await admin.from("tv_pairings").update({
        status: "approved",
        app_user_id: user.id,
        app_secret: link?.properties?.hashed_token ?? "",
        tracker_blob: body.trackerBlob ?? null,
      }).eq("code", body.code);
      return json({ ok: true });
    }

    if (body.action === "poll") {
      // tv_secret must match too — code alone isn't enough to collect the
      // minted login token, otherwise anyone who saw the pairing code (it's
      // shown on-screen / shareable) could steal the session instead of the
      // TV that actually created this pairing row.
      const { data: row } = await admin.from("tv_pairings")
        .select("id,status,expires_at,app_secret,tracker_blob")
        .eq("code", body.code).eq("tv_secret", body.tvSecret).maybeSingle();
      if (!row) return json({ ok: false, error: "not_found" }, 404);
      if (row.expires_at < Date.now()) return json({ ok: false, error: "expired" }, 410);
      if (row.status !== "approved") return json({ ok: true, status: "pending" });

      // Consume: the login token is one-time, so this row can't be polled
      // again for the same secret.
      await admin.from("tv_pairings").update({ status: "consumed" }).eq("id", row.id);
      return json({
        ok: true,
        status: "approved",
        appSecret: row.app_secret,
        trackerBlob: row.tracker_blob,
      });
    }

    return json({ ok: false, error: "bad_action" }, 400);
  } catch (_e) {
    return json({ ok: false, error: "server_error" }, 500);
  }
});

function json(b: unknown, status = 200) {
  return new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });
}
