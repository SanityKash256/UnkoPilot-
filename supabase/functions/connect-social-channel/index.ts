// SocialPilot: connect-social-channel
// Called from the frontend once a business owner finishes the WhatsApp/
// Instagram OAuth flow (or, for WhatsApp Cloud API test mode, once they've
// copied their phone_number_id from the Meta dashboard). Writes the
// social_channels row that social-webhook looks up to route incoming
// messages to the right business.
//
// Deploy with: supabase functions deploy connect-social-channel
// This one DOES verify the caller's JWT (default), so only a signed-in
// owner/admin of the business can call it -- RLS on social_channels also
// protects the table, this is belt-and-suspenders at the API layer.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization") ?? "";
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new Response("Unauthorized", { status: 401 });

  const { businessId, provider, externalAccountId, accountName } = await req.json();
  if (!businessId || !provider || !externalAccountId) {
    return new Response("Missing fields", { status: 400 });
  }

  // Confirm this user is an owner/admin of the business they're claiming --
  // RLS would also catch this on insert, but failing fast gives a clearer error.
  const { data: member } = await supabase
    .from("business_members")
    .select("role")
    .eq("business_id", businessId).eq("user_id", user.id).eq("status", "active")
    .maybeSingle();
  if (!member || !["owner", "admin"].includes(member.role)) {
    return new Response("Forbidden", { status: 403 });
  }

  // Plan's channel limit check (Starter=3, Group=3, Company=6) happens here
  // server-side too, not just in the UI -- a client could otherwise call
  // this function directly and bypass the frontend's check.
  const { data: biz } = await supabase.from("businesses").select("plan_id").eq("id", businessId).single();
  const { data: plan } = await supabase.from("plans").select("channels").eq("id", biz!.plan_id).single();
  const { count } = await supabase.from("social_channels").select("id", { count: "exact", head: true }).eq("business_id", businessId);
  if ((count ?? 0) >= (plan?.channels ?? 0)) {
    return new Response(JSON.stringify({ error: "Channel limit reached for your plan" }), { status: 400 });
  }

  const { data, error } = await supabase.from("social_channels").upsert({
    business_id: businessId,
    provider,
    external_account_id: externalAccountId,
    account_name: accountName ?? null,
    status: "connected",
    last_activity_at: new Date().toISOString()
    // access_token_reference intentionally omitted here: store the real
    // long-lived token in Supabase Vault (or your secrets manager) and
    // save only its reference id/key here -- never the raw token.
  }, { onConflict: "business_id,provider" }).select().single();

  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400 });
  return new Response(JSON.stringify(data), { status: 200 });
});
