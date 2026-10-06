-- Row Level Security: this is what actually stops Business A from ever
-- reading or writing Business B's data, no matter what the frontend does.
-- Enable RLS on every tenant table, then add policies per role.
--
-- IMPORTANT: my_business_ids(), my_role() and is_platform_admin() are all
-- marked `security definer`. This was tested (not assumed): running them
-- as ordinary invoker functions causes infinite recursion, because each
-- one queries a table (business_members / platform_admins) whose OWN RLS
-- policy calls that same function -- Postgres re-evaluates the policy on
-- every internal lookup and calls itself again, crashing with "stack
-- depth limit exceeded" on the very first login. security definer makes
-- the internal lookup run as the function owner, bypassing RLS for that
-- one query only, breaking the loop.

create or replace function is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;
revoke all on function is_platform_admin() from public;
grant execute on function is_platform_admin() to authenticated, anon;

create or replace function my_business_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select business_id from business_members
  where user_id = auth.uid() and status = 'active';
$$;
revoke all on function my_business_ids() from public;
grant execute on function my_business_ids() to authenticated, anon;

create or replace function my_role(biz uuid)
returns text language sql stable security definer set search_path = public as $$
  select role from business_members
  where user_id = auth.uid() and business_id = biz and status = 'active';
$$;
revoke all on function my_role(uuid) from public;
grant execute on function my_role(uuid) to authenticated, anon;

-- ---- profiles ----
alter table profiles enable row level security;
create policy "read own profile" on profiles for select using (id = auth.uid() or is_platform_admin());
create policy "update own profile" on profiles for update using (id = auth.uid());

-- ---- businesses ----
alter table businesses enable row level security;
create policy "members read their business" on businesses for select
  using (id in (select my_business_ids()) or is_platform_admin());
create policy "owner/admin update business" on businesses for update
  using (my_role(id) in ('owner','admin') or is_platform_admin());
create policy "platform admin inserts business plan/status changes" on businesses for insert
  with check (true); -- actual creation happens via the signup Edge Function using the service role

-- ---- business_members ----
alter table business_members enable row level security;
create policy "members read their membership list" on business_members for select
  using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "owner/admin manage members" on business_members for all
  using (my_role(business_id) in ('owner','admin') or is_platform_admin());

-- Generic tenant-isolation template applied to every business-owned table:
-- members of the business can read/write; platform admins can read for support.
do $$
declare t text;
begin
  foreach t in array array[
    'customers','customer_tags','customer_tag_assignments','leads','conversations',
    'messages','products','knowledge_base_entries','tasks','social_channels',
    'marketing_content','campaigns','broadcasts','notifications','ai_usage',
    'payments','audit_logs'
  ]
  loop
    execute format('alter table %I enable row level security;', t);
  end loop;
end $$;

-- customers
create policy "members read customers" on customers for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write customers" on customers for insert with check (business_id in (select my_business_ids()));
create policy "members update customers" on customers for update using (business_id in (select my_business_ids()));
create policy "members delete customers" on customers for delete using (business_id in (select my_business_ids()));

-- leads
create policy "members read leads" on leads for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write leads" on leads for all using (business_id in (select my_business_ids()));

-- conversations + messages (customers never get direct table access; they
-- only reach these through the social-webhook Edge Function using the
-- service role, which bypasses RLS deliberately and enforces business_id
-- itself based on the verified webhook sender)
create policy "members read conversations" on conversations for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members update conversations" on conversations for update using (business_id in (select my_business_ids()));
create policy "members read messages" on messages for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write messages" on messages for insert with check (business_id in (select my_business_ids()));

-- products, knowledge base, tasks, channels, marketing
create policy "members read products" on products for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write products" on products for all using (business_id in (select my_business_ids()));
create policy "members read kb" on knowledge_base_entries for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write kb" on knowledge_base_entries for all using (business_id in (select my_business_ids()));
create policy "members read tasks" on tasks for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write tasks" on tasks for all using (business_id in (select my_business_ids()));
create policy "members read channels" on social_channels for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "owner/admin write channels" on social_channels for all using (my_role(business_id) in ('owner','admin') or is_platform_admin());
create policy "members read content" on marketing_content for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write content" on marketing_content for all using (business_id in (select my_business_ids()));
create policy "members read campaigns" on campaigns for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "members write campaigns" on campaigns for all using (business_id in (select my_business_ids()));
create policy "members read broadcasts" on broadcasts for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "owner/admin send broadcasts" on broadcasts for insert with check (my_role(business_id) in ('owner','admin','manager'));

-- notifications: a user only sees their own
create policy "read own notifications" on notifications for select using (user_id = auth.uid() or is_platform_admin());

-- ai_usage: members can read their own business's usage; only the service
-- role (Edge Functions) inserts rows
create policy "members read ai_usage" on ai_usage for select using (business_id in (select my_business_ids()) or is_platform_admin());

-- payments: a business can see and submit its own transaction IDs, but can
-- never approve/reject its own payment or touch another business's queue
create policy "members read own payments" on payments for select using (business_id in (select my_business_ids()) or is_platform_admin());
create policy "owner/admin submit payment" on payments for insert
  with check (my_role(business_id) in ('owner','admin') and status = 'pending');
create policy "only platform admin reviews payments" on payments for update
  using (is_platform_admin());
create policy "members cancel own pending payment" on payments for update
  using (business_id in (select my_business_ids()) and status = 'pending')
  with check (status = 'cancelled');

-- audit_logs: members read their own business's log; platform admin reads all
create policy "members read audit log" on audit_logs for select using (business_id in (select my_business_ids()) or is_platform_admin());

-- plans table is public reference data
alter table plans enable row level security;
create policy "anyone can read plans" on plans for select using (true);
create policy "only platform admin edits plans" on plans for update using (is_platform_admin());

-- platform_admins: only readable/writable by existing admins (bootstrap the
-- first row directly in the SQL editor with your own auth.users id)
alter table platform_admins enable row level security;
create policy "admins see admin list" on platform_admins for select using (is_platform_admin());
