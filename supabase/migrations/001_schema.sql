-- SocialFlight (formerly UnkoPilot) core schema
-- Run in the Supabase SQL editor, or via `supabase db push` with the CLI.
-- Every tenant-owned table carries business_id; see 002_rls.sql for the
-- Row Level Security policies that actually enforce isolation.

create extension if not exists "pgcrypto";

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  avatar_url text,
  phone text,
  preferred_language text default 'en' check (preferred_language in ('en','lg','sw')),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table plans (
  id text primary key,                 -- 'trial' | 'starter' | 'group' | 'company'
  name text not null,
  price_ugx integer not null default 0,
  ai_limit integer not null,
  seats integer not null,
  channels integer not null,
  posts_limit integer not null default -1,   -- -1 = unlimited
  watermark boolean not null default true,
  schedule boolean not null default false,
  broadcast boolean not null default false,
  calendar boolean not null default false,
  campaigns boolean not null default false,
  report boolean not null default false
);
insert into plans (id, name, price_ugx, ai_limit, seats, channels, posts_limit, watermark, schedule, broadcast, calendar, campaigns, report) values
  ('trial','Free trial',0,200,1,6,15,true,true,true,true,true,true),
  ('starter','Starter',30000,300,1,3,20,true,false,false,false,false,false),
  ('group','Group',50000,1500,3,3,-1,false,true,true,false,false,false),
  ('company','Company',90000,5000,10,6,-1,false,true,true,true,true,true)
on conflict (id) do nothing;

create table businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  business_type text,
  country text,
  currency text default 'UGX',
  email text,
  phone text,
  website text,
  logo_url text,
  default_language text default 'en',
  plan_id text references plans(id) default 'trial',
  status text not null default 'active' check (status in ('active','suspended')),
  trial_ends_at timestamptz,
  paid_until timestamptz,
  ai_used integer not null default 0,
  posts_used integer not null default 0,
  auto_reply_on boolean not null default true,
  auto_reply_topics jsonb not null default '{"price":true,"delivery":true,"hours":true,"availability":true,"location":true,"payment":true,"greeting":true}',
  created_by uuid references profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table business_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role text not null check (role in ('owner','admin','manager','agent','marketing')),
  status text not null default 'active' check (status in ('active','disabled','invited')),
  joined_at timestamptz default now(),
  unique (business_id, user_id)
);

create table customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name text not null,
  phone text,
  email text,
  avatar_url text,
  country text,
  preferred_language text default 'unknown' check (preferred_language in ('en','lg','sw','unknown')),
  status text default 'Prospect',
  source text,
  notes text,
  assigned_to uuid references profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index idx_customers_business on customers(business_id);

create table customer_tags (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name text not null
);
create table customer_tag_assignments (
  customer_id uuid references customers(id) on delete cascade,
  tag_id uuid references customer_tags(id) on delete cascade,
  primary key (customer_id, tag_id)
);

create table leads (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  title text not null,
  stage text not null default 'New' check (stage in ('New','Contacted','Qualified','Proposal','Negotiation','Won','Lost')),
  value numeric default 0,
  currency text default 'UGX',
  priority text default 'normal' check (priority in ('low','normal','high')),
  assigned_to uuid references profiles(id),
  expected_close_date date,
  notes text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index idx_leads_business on leads(business_id);

create table conversations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  channel text not null,                 -- 'WhatsApp' | 'Instagram' | 'TikTok' | 'Facebook'
  external_conversation_id text,
  state text not null default 'needs' check (state in ('needs','ai','replied','resolved')),
  category text,                          -- 'order' | 'bargain' | 'complaint' | 'refund' | 'other' | null
  assigned_to uuid references profiles(id),
  priority text default 'normal',
  language text default 'en',
  last_message_at timestamptz default now(),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create index idx_conversations_business on conversations(business_id);
create index idx_conversations_external on conversations(external_conversation_id);

create table messages (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_type text not null check (sender_type in ('customer','agent','ai','note')),
  content text not null,
  language text,
  topic text,                              -- detected intent, for insights
  is_ai_generated boolean default false,
  external_message_id text,
  created_at timestamptz default now()
);
create index idx_messages_conversation on messages(conversation_id);

create table products (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name text not null,
  description text,
  category text,
  price numeric default 0,
  currency text default 'UGX',
  sku text,
  availability text default 'In stock' check (availability in ('In stock','Limited','Out of stock')),
  image_url text,
  status text default 'active',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table knowledge_base_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  title text not null,
  category text not null,   -- 'hours' | 'delivery' | 'payment' | 'location' | 'returns' | 'faq'
  content_en text,
  content_sw text,
  content_lg text,
  created_by uuid references profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table tasks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  title text not null,
  description text,
  customer_id uuid references customers(id) on delete set null,
  lead_id uuid references leads(id) on delete set null,
  assigned_to uuid references profiles(id),
  priority text default 'normal',
  status text default 'todo' check (status in ('todo','in_progress','done','cancelled')),
  due_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table social_channels (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  provider text not null check (provider in ('WhatsApp','Instagram','TikTok','Facebook','LinkedIn','X')),
  external_account_id text,
  account_name text,
  status text default 'connected' check (status in ('connected','error','expired')),
  access_token_reference text,     -- pointer into Vault / secrets manager, NEVER the raw token
  metadata jsonb default '{}',
  last_activity_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (business_id, provider)
);

create table marketing_content (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  created_by uuid references profiles(id),
  text_content text not null,
  image_url text,
  language text default 'en',
  status text default 'draft' check (status in ('draft','scheduled','published')),
  platforms text[] default '{}',
  scheduled_at timestamptz,
  published_at timestamptz,
  created_at timestamptz default now()
);

create table campaigns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name text not null,
  objective text,
  audience text,
  language text default 'en',
  start_date date,
  end_date date,
  status text default 'draft',
  created_at timestamptz default now()
);

create table broadcasts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  sent_by uuid references profiles(id),
  audience_filter text,
  recipient_count integer default 0,
  text_content text not null,
  created_at timestamptz default now()
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  user_id uuid references profiles(id),
  type text not null,
  title text,
  message text,
  read_at timestamptz,
  created_at timestamptz default now()
);

create table ai_usage (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  user_id uuid references profiles(id),
  feature text not null,          -- 'auto_reply' | 'draft' | 'summary' | 'translate' | 'caption' | 'poster'
  model text,
  input_tokens integer,
  output_tokens integer,
  estimated_cost numeric,
  created_at timestamptz default now()
);

-- Manual Mobile Money approval queue.
-- A client submits a transaction ID; the platform owner reviews it in the
-- Owner console (Payments tab) and approves or rejects it. Nothing here
-- talks to MTN automatically yet -- see the README for the upgrade path
-- once you have real MTN API/aggregator access.
create table payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  plan_id text not null references plans(id),
  amount_ugx integer not null,
  method text default 'MTN Mobile Money',
  payer_phone text not null,
  txn_id text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  reviewed_by uuid references profiles(id),
  reviewer_note text,
  created_at timestamptz default now(),
  reviewed_at timestamptz,
  unique (txn_id)   -- a transaction ID can only ever be used once, platform-wide
);
create index idx_payments_business on payments(business_id);
create index idx_payments_status on payments(status);

create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references businesses(id) on delete cascade,
  user_id uuid references profiles(id),
  action text not null,
  resource_type text,
  resource_id uuid,
  metadata jsonb default '{}',
  created_at timestamptz default now()
);

-- A platform-level "superadmin" flag. Kept separate from business_members
-- so the owner console's authorization check never has to look at any
-- business's data.
create table platform_admins (
  user_id uuid primary key references profiles(id) on delete cascade
);
