// TV<->phone device pairing. RLS lets clients insert ONLY a pending
// tv_pairings row (the TV does that directly, with its own tv_secret) — every
// read/update of that row goes through here via the service-role client.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

// The web tracker-login page (zangetsu.online/tv-connect) calls `drop` /
// `exchange` from a browser, so those need CORS. No cookies/credentials are
// used (only the public anon key header), so `*` is safe.
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const body = await req.json();

    // No-auth tracker drop: the web login page has done the tracker OAuth in
    // the phone browser and encrypted the session with the TV's nonce (which
    // never reaches us). We only store the ciphertext against a PENDING code —
    // exactly like a trackers-only `approve`, but without a Zangetsu account
    // (the user has no app). The nonce gates readability, so a stranger who
    // only knows the on-screen code can at worst drop an undecryptable blob.
    if (body.action === "drop") {
      const { data: row } = await admin.from("tv_pairings")
        .select("id,expires_at")
        .eq("code", body.code).eq("status", "pending").maybeSingle();
      if (!row || row.expires_at < Date.now()) {
        return json({ ok: false, error: "expired" }, 410);
      }
      if (typeof body.trackerBlob !== "string" || body.trackerBlob.length === 0) {
        return json({ ok: false, error: "bad_blob" }, 400);
      }
      await admin.from("tv_pairings").update({
        status: "approved",
        tracker_blob: body.trackerBlob,
      }).eq("code", body.code);
      return json({ ok: true });
    }

    // MAL / Simkl auth-code → token swap for the web login page (MAL blocks
    // browser CORS; Simkl needs the secret). We only ever return the session to
    // the browser, which encrypts it with the TV's nonce before `drop` — so we
    // never store a plaintext token.
    if (body.action === "exchange") {
      const { tracker, code, codeVerifier, redirectUri } = body;
      if (!code || !redirectUri) return json({ ok: false, error: "bad_request" }, 400);
      try {
        if (tracker === "anilist") {
          // AniList's implicit grant fails on an https web redirect, so the web
          // page uses response_type=code and we exchange it here with the TV
          // client's secret (client 48181 — separate from the app's 43052).
          const tr = await fetch("https://anilist.co/api/v2/oauth/token", {
            method: "POST",
            headers: { "content-type": "application/json", accept: "application/json" },
            body: JSON.stringify({
              grant_type: "authorization_code",
              client_id: "48181",
              client_secret: "2aK6Bb7QbCWvRh5ebNhP9igaj3TFlhmezSg4HEOS",
              redirect_uri: redirectUri,
              code,
            }),
          });
          const tj = await tr.json();
          if (!tj.access_token) return json({ ok: false, error: "anilist_token" }, 400);
          // viewerId is REQUIRED by the app's AniList session, so fetch it.
          let id = null, name = null, avatar = null;
          try {
            const ur = await fetch("https://graphql.anilist.co", {
              method: "POST",
              headers: {
                "content-type": "application/json",
                authorization: "Bearer " + tj.access_token,
              },
              body: JSON.stringify({ query: "{Viewer{id name avatar{medium}}}" }),
            });
            const uj = await ur.json();
            const v = uj?.data?.Viewer;
            if (v) { id = v.id; name = v.name; avatar = v?.avatar?.medium ?? null; }
          } catch (_) { /* fall through to the id check */ }
          if (id == null) return json({ ok: false, error: "anilist_viewer" }, 400);
          return json({ ok: true, session: {
            accessToken: tj.access_token,
            expiresAt: Date.now() + ((tj.expires_in ?? 31536000) * 1000),
            viewerId: id, viewerName: name, viewerAvatar: avatar,
          } });
        }
        if (tracker === "mal") {
          const tr = await fetch("https://myanimelist.net/v1/oauth2/token", {
            method: "POST",
            headers: { "content-type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams({
              client_id: "ac006943589381143c4c4e54eac93a89",
              grant_type: "authorization_code",
              code,
              code_verifier: codeVerifier ?? "",
              redirect_uri: redirectUri,
            }).toString(),
          });
          const tj = await tr.json();
          if (!tj.access_token) return json({ ok: false, error: "mal_token" }, 400);
          let name = null, avatar = null;
          try {
            const ur = await fetch(
              "https://api.myanimelist.net/v2/users/@me?fields=name,picture",
              { headers: { authorization: "Bearer " + tj.access_token } });
            const uj = await ur.json();
            name = uj.name ?? null; avatar = uj.picture ?? null;
          } catch (_) { /* viewer is cosmetic; token is what matters */ }
          return json({ ok: true, session: {
            accessToken: tj.access_token,
            refreshToken: tj.refresh_token ?? null,
            expiresAt: Date.now() + ((tj.expires_in ?? 2415600) * 1000),
            viewerName: name, viewerAvatar: avatar,
          } });
        }
        if (tracker === "simkl") {
          const CID = "8b847b09206ccdb0b3de4cc1293d6dd7d355821f5c179c57315da8ba9030eb53";
          const tr = await fetch("https://api.simkl.com/oauth/token", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              client_id: CID,
              client_secret: "34ba8e5ac7c8a5c27926dfdf78205e5b913de9928361cb5a243558239298c96d",
              redirect_uri: redirectUri,
              grant_type: "authorization_code",
              code,
            }),
          });
          const tj = await tr.json();
          if (!tj.access_token) return json({ ok: false, error: "simkl_token" }, 400);
          let name = null, avatar = null;
          try {
            const ur = await fetch("https://api.simkl.com/users/settings", {
              method: "POST",
              headers: {
                authorization: "Bearer " + tj.access_token,
                "simkl-api-key": CID,
                "content-type": "application/json",
              },
            });
            const uj = await ur.json();
            name = uj?.user?.name ?? null; avatar = uj?.user?.avatar ?? null;
          } catch (_) { /* cosmetic */ }
          return json({ ok: true, session: {
            accessToken: tj.access_token, viewerName: name, viewerAvatar: avatar,
          } });
        }
        return json({ ok: false, error: "bad_tracker" }, 400);
      } catch (_e) {
        return json({ ok: false, error: "exchange_failed" }, 500);
      }
    }

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
      // via poll() and gated there by tv_secret (see below). Skipped for a
      // trackers-only pairing (TV already signed in, just wants one more
      // tracker) — no need to mint a login token nobody's going to consume.
      const trackersOnly = body.trackersOnly === true;
      let appSecret = "";
      if (!trackersOnly) {
        const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
          type: "magiclink",
          email: user.email!,
        });
        if (linkErr) return json({ ok: false, error: "server_error" }, 500);
        appSecret = link?.properties?.hashed_token ?? "";
      }

      // Hand back the hashed_token (not the 6-digit email_otp): the TV is signed
      // OUT and has no email, so it must verify via verifyOtp({ tokenHash }) which
      // needs no email. The email_otp would require the address we don't send.
      await admin.from("tv_pairings").update({
        status: "approved",
        app_user_id: user.id,
        app_secret: appSecret,
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
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}
