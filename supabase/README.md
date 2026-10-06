# SocialPilot — Supabase backend starter

This folder is everything needed to move SocialPilot (built from the original
UnkoPilot PRD) off browser `localStorage` and onto a real, multi-tenant
Postgres database with working WhatsApp/Instagram message ingestion. It was
generated and tested against a real local Postgres instance, but never
connected to any live Supabase project — the environment that built this has
no outbound network access, so nothing here has touched your actual
Supabase instance yet. You'll run these steps yourself (15–20 minutes for
the database, longer for real channel credentials).

## What's actually possible right now vs. what needs more from you

| Claim | Reality |
|---|---|
| "Connect to your Supabase link and store data" | Can't be done directly — no outbound network from the build environment. The SQL below is the complete, ready-to-paste schema instead. |
| "Channels with no limitations" | Doesn't exist on any platform — Meta and TikTok gate message access behind developer apps and review. WhatsApp's test mode is the fastest honest path (minutes, not days). TikTok has no public inbox API at all — it can only be a *posting* target, not an incoming-message channel. |
| "Deploy the site and give a link" | Already live: **https://claude.ai/artifact/8ErjHU54DaYDb7ZypPX22c** — real and shareable now. A custom-domain production deploy needs your own Vercel/Supabase accounts. |

## 1. Create the database (5 minutes)

1. Create a project at supabase.com (free tier is fine to start).
2. Open **SQL Editor** → paste `migrations/001_schema.sql` → Run.
3. Paste `migrations/002_rls.sql` → Run. This is what actually stops Business
   A from ever reading Business B's data — it's enforced in Postgres, not
   just hidden in the UI. (Both files were run end-to-end against a real
   local Postgres 16 instance before being added here, including a test
   that tried to read/write across two simulated businesses and confirmed
   the database itself rejects it — see the commit for details.)
4. Make yourself the platform owner: in SQL editor —
   ```sql
   insert into platform_admins (user_id) values ('<your-auth-user-id>');
   ```
   (Sign up through Supabase Auth first, then find your id in
   Authentication → Users.)

## 2. Deploy the Edge Functions

```bash
npm install -g supabase
supabase login
supabase link --project-ref <your-project-ref>

supabase secrets set META_VERIFY_TOKEN=choose-any-random-string
supabase secrets set META_APP_SECRET=<from Meta App Dashboard>

supabase functions deploy social-webhook --no-verify-jwt
supabase functions deploy connect-social-channel
```

`--no-verify-jwt` on `social-webhook` is intentional and correct: Meta calls
this endpoint directly, with no Supabase session, so it authenticates via the
`X-Hub-Signature-256` HMAC check inside the function instead (see the code
comments). Every other function keeps the default JWT check.

## 3. Get a real WhatsApp channel connected (fastest real option)

1. developers.facebook.com → **My Apps** → Create App → type "Business".
2. Add the **WhatsApp** product. Meta gives you a free test phone number
   immediately — no business verification needed for this step.
3. **WhatsApp → Configuration → Webhook**: set the Callback URL to your
   deployed `social-webhook` URL, Verify Token to the `META_VERIFY_TOKEN`
   you set above, subscribe to the `messages` field.
4. Copy the test number's **Phone Number ID**. Insert it as a channel:
   ```sql
   insert into social_channels (business_id, provider, external_account_id, account_name, status)
   values ('<your business id>', 'WhatsApp', '<phone_number_id>', '+1 555 0100', 'connected');
   ```
   (Once `connect-social-channel` is wired into the SocialPilot UI, this
   becomes a button instead of a manual insert.)
5. Under **API Setup**, add your own phone as a test recipient, then message
   that test number from your phone. It should land in the `messages` table
   within a second or two — confirming the pipe actually works end to end.
6. Going from the free test number to your own business WhatsApp number
   requires Meta Business Verification (your business documents, a few days'
   review). The test number is the right way to prove out the integration
   first.

Instagram/Messenger follow the same App, adding the **Messenger** product
and an Instagram-linked Page — same webhook endpoint, same function handles
both (see the `entry.messaging` branch in `social-webhook/index.ts`).

TikTok: no public inbox API exists to receive customer DMs. Keep it as a
*posting* destination in Marketing Studio and don't promise it as an inbox
channel.

## 4. Wire the frontend

Replace the `localStorage`-backed `DB` object in the SocialPilot frontend
with Supabase client calls. The shapes match closely by design —
`DB.businesses` → `businesses` table, `DB.data[bizId].customers` →
`customers` filtered by `business_id`, etc. The biggest behavior change: the
rule-based `route()` function that decides auto-reply vs. human-queue should
move into an `ai-auto-reply` Edge Function (not included here) that a
Postgres trigger or the webhook calls after every inserted customer message
— same decision logic, just server-side and swappable for a real LLM call
later.

## Files in this folder

- `migrations/001_schema.sql` — every table (businesses, customers, leads,
  conversations, messages, products, knowledge base, payments, etc.)
- `migrations/002_rls.sql` — Row Level Security policies enforcing tenant
  isolation and the owner-only payment-approval rule
- `functions/social-webhook/` — receives WhatsApp + Instagram/Messenger
  messages, verifies Meta's signature, stores them
- `functions/connect-social-channel/` — lets an owner/admin register a
  channel, enforcing the plan's channel limit server-side too
