-- Bougainvilla CRM — Supabase schema
--
-- Run once in Supabase → SQL Editor → New query → Run.
--
-- Everything the dashboard shows comes from here. n8n writes on every
-- Instagram message; the dashboard reads one function. No other store.

-- ─────────────────────────────────────────────────────────────
-- guests, one row per person per channel
-- ─────────────────────────────────────────────────────────────
create table if not exists leads (
  id             uuid primary key default gen_random_uuid(),
  channel        text        not null,
  sender_id      text        not null,
  display_name   text,
  phone          text,
  email          text,
  lead_stage     text,
  booking_status text        default 'enquiry',
  intent         text,
  check_in       date,
  check_out      date,
  guest_count    int,
  property_id    text,
  needs_human    boolean     default false,
  first_seen_at  timestamptz default now(),
  last_seen_at   timestamptz default now(),
  unique (channel, sender_id)
);

create index if not exists leads_last_seen  on leads (last_seen_at desc);
create index if not exists leads_needs_human on leads (needs_human) where needs_human;

-- ─────────────────────────────────────────────────────────────
-- every message, in and out
--
-- provider_message_id is UNIQUE, which is what stops Meta's webhook
-- retries producing a second reply: the insert simply conflicts.
-- ─────────────────────────────────────────────────────────────
create table if not exists messages (
  id                  uuid primary key default gen_random_uuid(),
  channel             text not null,
  sender_id           text not null,
  direction           text not null check (direction in ('in','out')),
  provider_message_id text unique,
  body                text,
  intent              text,
  booking_status      text,
  needs_human         boolean default false,
  created_at          timestamptz default now()
);

create index if not exists messages_created on messages (created_at desc);
create index if not exists messages_sender  on messages (channel, sender_id, created_at desc);

-- ─────────────────────────────────────────────────────────────
-- one call, everything the dashboard needs
--
-- Returns real counts only. Anything Bougainvilla does not yet track
-- (revenue, ratings) is omitted rather than faked, and the dashboard
-- renders those tiles as "not tracked yet".
-- ─────────────────────────────────────────────────────────────
create or replace function dashboard_metrics()
returns json
language sql
stable
as $$
  with
  windowed as (
    select
      count(*) filter (where direction = 'in')                                as messages_in,
      count(*) filter (where direction = 'out')                               as messages_out,
      count(*) filter (where created_at >= date_trunc('day', now()))          as messages_today,
      count(distinct sender_id)                                               as people
    from messages
  ),
  lead_counts as (
    select
      count(*)                                                                as total_leads,
      count(*) filter (where needs_human)                                     as needs_human,
      count(*) filter (where last_seen_at >= now() - interval '7 days')       as active_7d
    from leads
  ),
  by_channel as (
    select channel, count(distinct sender_id) as n
    from messages group by channel
  ),
  daily as (
    -- keep the date itself: ordering by the formatted label would sort
    -- "01 Sep" before "22 Aug" and scramble the chart
    select d::date                as day,
           to_char(d, 'DD Mon')   as label,
           (select count(*) from messages m
             where m.direction = 'in' and m.created_at::date = d::date) as value
    from generate_series((now() - interval '13 days')::date, now()::date, '1 day') d
  ),
  recent as (
    select l.sender_id, l.display_name, l.lead_stage, l.booking_status,
           l.needs_human, l.last_seen_at,
           (select body from messages m
             where m.sender_id = l.sender_id and m.direction = 'in'
             order by m.created_at desc limit 1) as last_message
    from leads l order by l.last_seen_at desc limit 10
  )
  select json_build_object(
    'stats', json_build_object(
      'conversations',  (select people        from windowed),
      'active_leads',   (select active_7d     from lead_counts),
      'messages_today', (select messages_today from windowed),
      'needs_human',    (select needs_human   from lead_counts),
      'messages_in',    (select messages_in   from windowed),
      'messages_out',   (select messages_out  from windowed),
      'total_leads',    (select total_leads   from lead_counts)
    ),
    'channels',       (select coalesce(json_object_agg(channel, n), '{}'::json) from by_channel),
    'message_series', json_build_object(
      'labels', (select coalesce(json_agg(label order by day), '[]'::json) from daily),
      'values', (select coalesce(json_agg(value order by day), '[]'::json) from daily)
    ),
    'recent_leads',   (select coalesce(json_agg(recent), '[]'::json) from recent)
  );
$$;

-- ─────────────────────────────────────────────────────────────
-- Access
--
-- RLS on, with no policies: the anon key can read nothing. n8n uses the
-- service_role key, which bypasses RLS, and n8n is the only client.
-- The dashboard never talks to Supabase directly — it goes through n8n.
-- ─────────────────────────────────────────────────────────────
alter table leads    enable row level security;
alter table messages enable row level security;

-- ─────────────────────────────────────────────────────────────
-- One call per handled message.
--
-- Upserts the guest and records both sides of the exchange. Dates and
-- numbers arrive as text because the model may return "" for anything it
-- does not know; nullif keeps those out of the typed columns.
--
-- Inserts are ON CONFLICT DO NOTHING against provider_message_id, so a
-- Meta webhook retry re-runs this harmlessly instead of double-counting.
-- ─────────────────────────────────────────────────────────────
create or replace function record_exchange(
  p_channel         text,
  p_sender_id       text,
  p_in_message_id   text default null,
  p_in_body         text default null,
  p_out_message_id  text default null,
  p_out_body        text default null,
  p_intent          text default null,
  p_lead_stage      text default null,
  p_booking_status  text default null,
  p_needs_human     boolean default false,
  p_check_in        text default null,
  p_check_out       text default null,
  p_guest_count     text default null,
  p_property_id     text default null,
  p_display_name    text default null
) returns json
language plpgsql
as $$
declare
  v_check_in  date;
  v_check_out date;
  v_guests    int;
begin
  begin v_check_in  := nullif(trim(coalesce(p_check_in, '')),  '')::date; exception when others then v_check_in  := null; end;
  begin v_check_out := nullif(trim(coalesce(p_check_out, '')), '')::date; exception when others then v_check_out := null; end;
  begin v_guests    := nullif(trim(coalesce(p_guest_count,'')),'')::int;  exception when others then v_guests    := null; end;

  insert into leads (channel, sender_id, display_name, lead_stage, booking_status,
                     intent, check_in, check_out, guest_count, property_id,
                     needs_human, last_seen_at)
  values (p_channel, p_sender_id, nullif(p_display_name,''), p_lead_stage, p_booking_status,
          p_intent, v_check_in, v_check_out, v_guests, nullif(p_property_id,''),
          coalesce(p_needs_human,false), now())
  on conflict (channel, sender_id) do update set
    display_name   = coalesce(excluded.display_name,   leads.display_name),
    lead_stage     = coalesce(excluded.lead_stage,     leads.lead_stage),
    booking_status = coalesce(excluded.booking_status, leads.booking_status),
    intent         = coalesce(excluded.intent,         leads.intent),
    check_in       = coalesce(excluded.check_in,       leads.check_in),
    check_out      = coalesce(excluded.check_out,      leads.check_out),
    guest_count    = coalesce(excluded.guest_count,    leads.guest_count),
    property_id    = coalesce(excluded.property_id,    leads.property_id),
    needs_human    = excluded.needs_human,
    last_seen_at   = now();

  if nullif(p_in_body, '') is not null then
    insert into messages (channel, sender_id, direction, provider_message_id,
                          body, intent, booking_status, needs_human)
    values (p_channel, p_sender_id, 'in', nullif(p_in_message_id,''),
            p_in_body, p_intent, p_booking_status, coalesce(p_needs_human,false))
    on conflict (provider_message_id) do nothing;
  end if;

  if nullif(p_out_body, '') is not null then
    insert into messages (channel, sender_id, direction, provider_message_id,
                          body, intent, booking_status, needs_human)
    values (p_channel, p_sender_id, 'out', nullif(p_out_message_id,''),
            p_out_body, p_intent, p_booking_status, coalesce(p_needs_human,false))
    on conflict (provider_message_id) do nothing;
  end if;

  return json_build_object('ok', true, 'sender_id', p_sender_id);
end;
$$;
