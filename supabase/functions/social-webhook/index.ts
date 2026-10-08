// SocialFlight: social-webhook
// One Edge Function endpoint handles both WhatsApp Cloud API and
// Instagram/Facebook Messenger webhooks (Meta uses the same envelope
// shape for both). TikTok is NOT handled here -- TikTok has no push
// webhook for organic comments, so a comment-reply integration needs a
// separate polling function (see supabase/README.md). Deploy with:
//
//   supabase functions deploy social-webhook --no-verify-jwt
//
// Then register this function's URL as the webhook callback URL in your
// Meta App Dashboard, for both the WhatsApp product and Messenger product.
//
// Required secrets (set with `supabase secrets set KEY=value`):
//   META_VERIFY_TOKEN      - a string you invent, entered in Meta's dashboard too
//   META_APP_SECRET        - from Meta App Dashboard, used to verify the
//                             X-Hub-Signature-256 header so random requests
//                             can't inject fake messages
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY   - service role bypasses RLS; this function
//                             enforces business_id itself from the verified
//                             sender, which is why it's safe to use here
//   OPENAI_API_KEY          - only needed once you wire in ai-auto-reply;
//                             left out of this file on purpose

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

async function verifySignature(req: Request, rawBody: string): Promise<boolean> {
  const sig = req.headers.get("x-hub-signature-256");
  const secret = Deno.env.get("META_APP_SECRET");
  if (!sig || !secret) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const expected = "sha256=" + Array.from(new Uint8Array(mac)).map(b => b.toString(16).padStart(2, "0")).join("");
  return sig === expected;
}

// Finds which business owns this WhatsApp/Instagram/Facebook account.
// social_channels.external_account_id stores the phone_number_id (WhatsApp)
// or the Page/IG-scoped user id (Messenger/Instagram).
async function resolveBusiness(provider: string, externalAccountId: string) {
  const { data } = await supabase
    .from("social_channels")
    .select("business_id")
    .eq("provider", provider)
    .eq("external_account_id", externalAccountId)
    .eq("status", "connected")
    .maybeSingle();
  return data?.business_id ?? null;
}

async function findOrCreateCustomer(businessId: string, phoneOrId: string, name: string | null) {
  const { data: existing } = await supabase
    .from("customers").select("id, preferred_language")
    .eq("business_id", businessId).eq("phone", phoneOrId).maybeSingle();
  if (existing) return existing;
  const { data: created } = await supabase
    .from("customers")
    .insert({ business_id: businessId, phone: phoneOrId, name: name || "New customer", source: "WhatsApp", status: "Prospect" })
    .select("id, preferred_language").single();
  return created!;
}

async function findOrCreateConversation(businessId: string, customerId: string, channel: string, externalConvId: string) {
  const { data: existing } = await supabase
    .from("conversations").select("id")
    .eq("business_id", businessId).eq("customer_id", customerId).maybeSingle();
  if (existing) return existing.id;
  const { data: created } = await supabase
    .from("conversations")
    .insert({ business_id: businessId, customer_id: customerId, channel, external_conversation_id: externalConvId, state: "needs" })
    .select("id").single();
  return created!.id;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // --- Meta's webhook verification handshake (GET) ---
  // Meta calls this once when you register the webhook URL in the dashboard.
  if (req.method === "GET") {
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge");
    if (mode === "subscribe" && token === Deno.env.get("META_VERIFY_TOKEN")) {
      return new Response(challenge, { status: 200 });
    }
    return new Response("Forbidden", { status: 403 });
  }

  // --- Incoming message events (POST) ---
  if (req.method === "POST") {
    const rawBody = await req.text();
    if (!(await verifySignature(req, rawBody))) {
      return new Response("Invalid signature", { status: 401 });
    }
    const body = JSON.parse(rawBody);

    for (const entry of body.entry ?? []) {
      // WhatsApp Cloud API shape
      for (const change of entry.changes ?? []) {
        if (change.field !== "messages") continue;
        const value = change.value;
        const phoneNumberId = value?.metadata?.phone_number_id;
        if (!phoneNumberId) continue;
        const businessId = await resolveBusiness("WhatsApp", phoneNumberId);
        if (!businessId) continue; // not a channel we have on file -- ignore

        for (const msg of value.messages ?? []) {
          if (msg.type !== "text") continue; // extend here for image/audio/location etc.
          const fromPhone = msg.from;
          const contactName = value.contacts?.find((c: any) => c.wa_id === fromPhone)?.profile?.name ?? null;
          const customer = await findOrCreateCustomer(businessId, fromPhone, contactName);
          const conversationId = await findOrCreateConversation(businessId, customer.id, "WhatsApp", fromPhone);

          await supabase.from("messages").insert({
            business_id: businessId,
            conversation_id: conversationId,
            sender_type: "customer",
            content: msg.text.body,
            external_message_id: msg.id
          });
          await supabase.from("conversations")
            .update({ last_message_at: new Date().toISOString(), state: "needs" })
            .eq("id", conversationId);

          // This is the hand-off point: call your ai-auto-reply function
          // here (or let a database webhook / cron trigger it) to decide
          // whether this message is answerable automatically -- mirroring
          // the route() logic in the SocialFlight prototype -- or whether
          // it should stay in the human queue.
          //
          // await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/ai-auto-reply`, {
          //   method: "POST",
          //   headers: { Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}` },
          //   body: JSON.stringify({ conversationId })
          // });
        }
      }

      // Instagram / Messenger shape (same App, different field name)
      for (const msgEvent of entry.messaging ?? []) {
        const pageId = entry.id;
        const businessId = await resolveBusiness("Instagram", pageId) ?? await resolveBusiness("Facebook", pageId);
        if (!businessId || !msgEvent.message?.text) continue;
        const senderId = msgEvent.sender.id;
        const customer = await findOrCreateCustomer(businessId, senderId, null);
        const conversationId = await findOrCreateConversation(businessId, customer.id, "Instagram", senderId);
        await supabase.from("messages").insert({
          business_id: businessId,
          conversation_id: conversationId,
          sender_type: "customer",
          content: msgEvent.message.text,
          external_message_id: msgEvent.message.mid
        });
      }
    }
    return new Response("EVENT_RECEIVED", { status: 200 });
  }

  return new Response("Method not allowed", { status: 405 });
});
