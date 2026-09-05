
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
-- Booking slots
--
-- These are the whole point of the deterministic flow. The guest's
-- answers live in COLUMNS, not in a chat transcript, so the agent never
-- has to re-derive them from text and never asks twice.
--
-- conv_state is computed from the slots on every turn, never trusted
-- from the model. It is stored only so the dashboard and a human can
-- see where a conversation got to.
-- ─────────────────────────────────────────────────────────────
alter table leads add column if not exists nights          int;
alter table leads add column if not exists occasion        text;
alter table leads add column if not exists conv_state      text default 'NEW';
alter table leads add column if not exists quoted_total    numeric;
alter table leads add column if not exists quoted_nights   int;
alter table leads add column if not exists quoted_check_in date;
alter table leads add column if not exists hold_expires_at timestamptz;
alter table leads add column if not exists asked_slot      text;
alter table leads add column if not exists asked_count     int default 0;
alter table leads add column if not exists last_language   text;
alter table leads add column if not exists offered_check_in date;

create index if not exists leads_state on leads (conv_state);
create index if not exists leads_hold  on leads (hold_expires_at) where hold_expires_at is not null;

-- ─────────────────────────────────────────────────────────────
-- Tariff and cost configuration — one row, id = 1
--
-- The discount ladder is DATA, not a judgement call. The agent reads a
-- price out of here and states it; it never negotiates and never rounds.
-- To change pricing, update this row. Nothing else needs redeploying.
--
-- weekend_dows uses Postgres day numbering: 0=Sun 1=Mon … 5=Fri 6=Sat.
-- The default {5,6,0} is Fri/Sat/Sun. Remove 5 to make Friday a weekday
-- and about four nights a month move into the discountable bucket.
--
-- fixed_monthly is deliberately NULL until real numbers are supplied.
-- The dashboard omits profit and break-even rather than inventing them.
-- ─────────────────────────────────────────────────────────────
create table if not exists pricing_config (
  id                 int primary key default 1 check (id = 1),
  base_weekend       numeric not null default 30000,
  base_weekday       numeric not null default 28000,
  per_pax_weekend    numeric not null default 3000,
  per_pax_weekday    numeric not null default 2800,
  base_pax           int     not null default 10,
  max_pax            int     not null default 20,
  weekend_dows       int[]   not null default '{5,6,0}',
  weekday_floor      numeric not null default 17000,
  midweek3_discount  numeric not null default 0.25,
  sunday_addon       numeric not null default 12000,
  ladder             jsonb   not null default '[
    {"min_days": 22, "price": 28000},
    {"min_days": 15, "price": 25000},
    {"min_days":  8, "price": 22500},
    {"min_days":  4, "price": 19500},
    {"min_days":  0, "price": 17000}]'::jsonb,
  fixed_monthly      numeric,
  variable_per_night numeric not null default 3000,
  target_profit      numeric,
  cost_lines         jsonb   not null default '{}'::jsonb,
  hold_hours         int     not null default 24
);

insert into pricing_config (id) values (1) on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────
-- The costs, as supplied. Four of eight lines are real; the rest are
-- null, and null is not zero — it is "nobody has told us yet". They are
-- listed by name so the gap is visible instead of silently understating
-- the cost base and overstating the profit.
--
-- Each of these updates is guarded on `is null`, so re-running this file
-- never overwrites a number you have since corrected.
-- ─────────────────────────────────────────────────────────────
update pricing_config set cost_lines = jsonb_build_object(
    'social_media', 18000,
    'caretaker',    15000,
    'manager',      25000,
    'electricity',  30000,
    'chef',         null,
    'internet',     null,
    'maintenance',  null,
    'emi',          null)
 where id = 1 and cost_lines = '{}'::jsonb;

-- 18000 + 15000 + 25000 + 30000. Raise this as the missing lines arrive.
update pricing_config set fixed_monthly = 88000
 where id = 1 and fixed_monthly is null;

-- The reference month: 15 nights sold — every weekend night plus one
-- weekday — with weekends taken as Fri–Mon stays and the weekday at the
-- 8–14 day tier. The conservative corner of that scenario, deliberately:
-- a target you beat is worth more than one you admire.
update pricing_config set target_profit = 237500
 where id = 1 and target_profit is null;

-- ─────────────────────────────────────────────────────────────
-- What one night costs, before any discount.
-- ─────────────────────────────────────────────────────────────
create or replace function list_price_for(p_night date)
returns numeric
language sql stable
as $$
  select case
    when extract(dow from p_night)::int = any(c.weekend_dows) then c.base_weekend
    else c.base_weekday
  end
  from pricing_config c where c.id = 1;
$$;

-- ─────────────────────────────────────────────────────────────
-- The tariff, night by night.
--
-- Weekends never discount: they run 79–92% full, so a discount there is
-- margin given away to guests who would have paid list. Weekdays fall
-- down the ladder as the date approaches, because an unsold night is
-- worth nothing at midnight — but never below weekday_floor, or you
-- teach the market to wait.
--
-- p_asof is the date the quote is made from, so the same stay can be
-- re-priced later and the dashboard can reprice history at list.
-- ─────────────────────────────────────────────────────────────
create or replace function tariff_nightly(
  p_check_in date,
  p_nights   int,
  p_pax      int  default null,
  p_asof     date default null
) returns table (
  night      date,
  dow        int,
  kind       text,
  list_price numeric,
  price      numeric,
  extra_pax  numeric,
  reason     text
)
language plpgsql stable
as $$
declare
  c              pricing_config%rowtype;
  v_asof         date := coalesce(p_asof, current_date);
  v_lead         int;
  v_ladder       numeric;
  v_weekday_n    int;
  v_has_fri_sat  boolean;
  v_extra        int;
  d              date;
  v_dow          int;
  v_is_we        boolean;
  v_price        numeric;
  v_reason       text;
begin
  select * into c from pricing_config where id = 1;
  if p_nights is null or p_nights < 1 then p_nights := 1; end if;

  v_lead  := greatest(0, p_check_in - v_asof);
  v_extra := greatest(0, coalesce(p_pax, c.base_pax) - c.base_pax);

  -- shape of the whole stay: needed for the midweek and Sunday rules
  select count(*) filter (where not (extract(dow from g)::int = any(c.weekend_dows))),
         bool_or(extract(dow from g)::int in (5, 6))
    into v_weekday_n, v_has_fri_sat
  from generate_series(p_check_in, p_check_in + (p_nights - 1), '1 day') g;

  -- the ladder tier for this lead time
  select (t->>'price')::numeric into v_ladder
  from jsonb_array_elements(c.ladder) t
  where v_lead >= (t->>'min_days')::int
  order by (t->>'min_days')::int desc
  limit 1;
  v_ladder := coalesce(v_ladder, c.base_weekday);

  for i in 0 .. p_nights - 1 loop
    d      := p_check_in + i;
    v_dow  := extract(dow from d)::int;
    v_is_we := v_dow = any(c.weekend_dows);

    if v_is_we then
      -- a Sunday tacked onto a Fri/Sat stay: they are already here and
      -- the room is already dirty, so it is nearly pure contribution
      if v_dow = 0 and v_has_fri_sat and p_nights > 1 then
        v_price  := c.sunday_addon;
        v_reason := 'sunday_addon';
      else
        v_price  := c.base_weekend;
        v_reason := 'weekend_list';
      end if;
    else
      v_price  := v_ladder;
      v_reason := 'lead_' || v_lead || 'd';

      -- three or more Mon–Thu nights: one arrival, one changeover, one
      -- deep clean. The cheapest revenue the villa will ever earn.
      if v_weekday_n >= 3 and c.base_weekday * (1 - c.midweek3_discount) < v_price then
        v_price  := c.base_weekday * (1 - c.midweek3_discount);
        v_reason := 'midweek3';
      end if;

      if v_price < c.weekday_floor then
        v_price  := c.weekday_floor;
        v_reason := 'floor';
      end if;
    end if;

    night      := d;
    dow        := v_dow;
    kind       := case when v_is_we then 'weekend' else 'weekday' end;
    list_price := case when v_is_we then c.base_weekend else c.base_weekday end;
    price      := v_price;
    extra_pax  := v_extra * case when v_is_we then c.per_pax_weekend else c.per_pax_weekday end;
    reason     := v_reason;
    return next;
  end loop;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Availability AND price in one call.
--
-- The old flow asked the model to check availability with one tool and
-- then had nothing to say about money. This returns both, so the agent
-- can quote in the same breath as it confirms the dates are free.
--
-- Everything arrives as text: the extraction step may return "" for
-- anything the guest has not said yet. Bad input returns an error
-- object rather than raising, so the guest still gets a reply.
-- ─────────────────────────────────────────────────────────────
create or replace function quote_stay(
  p_check_in    text,
  p_nights      text default '1',
  p_pax         text default null,
  p_property_id text default 'bougainvilla'
) returns json
language plpgsql stable
as $$
declare
  c        pricing_config%rowtype;
  v_in     date;
  v_n      int;
  v_pax    int;
  v_out    date;
  v_count  int;
  v_confl  json;
  v_free   date;
  v_rows   json;
  v_villa  numeric;
  v_extra  numeric;
  v_list   numeric;
begin
  select * into c from pricing_config where id = 1;

  begin v_in := nullif(trim(coalesce(p_check_in,'')), '')::date;
  exception when others then
    return json_build_object('error','bad_check_in',
      'message','Could not read the check-in date.');
  end;
  if v_in is null then
    return json_build_object('error','missing_check_in',
      'message','No check-in date given.');
  end if;

  begin v_n := nullif(trim(coalesce(p_nights,'')), '')::int;
  exception when others then v_n := null; end;
  if v_n is null or v_n < 1 then v_n := 1; end if;
  if v_n > 30 then v_n := 30; end if;

  begin v_pax := nullif(trim(coalesce(p_pax,'')), '')::int;
  exception when others then v_pax := null; end;

  v_out := v_in + v_n;

  select count(*), coalesce(json_agg(json_build_object(
           'from', l.check_in, 'to', greatest(l.check_out, l.check_in + 1),
           'status', l.booking_status)), '[]'::json)
    into v_count, v_confl
  from leads l
  where l.check_in is not null
    and (l.booking_status in ('booked','occupied')
         or (l.booking_status = 'held' and l.hold_expires_at > now()))
    and coalesce(l.property_id,'bougainvilla') = coalesce(p_property_id,'bougainvilla')
    and v_in < greatest(l.check_out, l.check_in + 1)
    and l.check_in < v_out;

  if v_count > 0 then
    select min(x.cand) into v_free
    from (select g::date as cand
            from generate_series(v_in, v_in + 180, '1 day') g) x
    where not exists (
      select 1 from leads l
      where l.check_in is not null
        and (l.booking_status in ('booked','occupied')
         or (l.booking_status = 'held' and l.hold_expires_at > now()))
        and coalesce(l.property_id,'bougainvilla') = coalesce(p_property_id,'bougainvilla')
        and x.cand < greatest(l.check_out, l.check_in + 1)
        and l.check_in < x.cand + v_n);

    return json_build_object(
      'available', false, 'check_in', v_in, 'check_out', v_out, 'nights', v_n,
      'pax', v_pax, 'conflicts', v_confl, 'next_available_from', v_free,
      'message', 'Those dates are taken.');
  end if;

  select coalesce(json_agg(json_build_object(
           'date', t.night, 'kind', t.kind, 'list', t.list_price,
           'price', t.price, 'reason', t.reason) order by t.night), '[]'::json),
         coalesce(sum(t.price), 0),
         coalesce(sum(t.extra_pax), 0),
         coalesce(sum(t.list_price), 0)
    into v_rows, v_villa, v_extra, v_list
  from tariff_nightly(v_in, v_n, v_pax, current_date) t;

  return json_build_object(
    'available',    true,
    'check_in',     v_in,
    'check_out',    v_out,
    'nights',       v_n,
    'pax',          v_pax,
    'over_capacity', v_pax is not null and v_pax > c.max_pax,
    'base_pax',     c.base_pax,
    'lead_days',    greatest(0, v_in - current_date),
    'nightly',      v_rows,
    'villa_total',  v_villa,
    'extra_pax_total', v_extra,
    'total',        v_villa + v_extra,
    'list_total',   v_list + v_extra,
    'discount',     (v_list - v_villa),
    'discount_pct', case when v_list > 0
                      then round((v_list - v_villa) * 100 / v_list) else 0 end,
    'hold_hours',   c.hold_hours,
    'message',      'These dates are free.');
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Everything the agent needs to know before it opens its mouth.
--
-- One call at the top of every turn: the slots we already have, the
-- last few messages for tone, and whether a hold is live. This is what
-- replaces the in-RAM window buffer that was losing the answers.
-- ─────────────────────────────────────────────────────────────
create or replace function get_guest_state(
  p_channel   text,
  p_sender_id text
) returns json
language sql stable
as $$
  select json_build_object(
    'found', l.id is not null,
    'today', current_date,
    'slots', json_build_object(
      'check_in',    l.check_in,
      'nights',      l.nights,
      'pax',         l.guest_count,
      'occasion',    l.occasion,
      'guest_name',  l.display_name,
      'phone',       l.phone
    ),
    'conv_state',      coalesce(l.conv_state, 'NEW'),
    'asked_slot',      l.asked_slot,
    'asked_count',     coalesce(l.asked_count, 0),
    'needs_human',     coalesce(l.needs_human, false),
    'last_language',   l.last_language,
    'offered_check_in', l.offered_check_in,
    'quoted_total',    l.quoted_total,
    'quoted_check_in', l.quoted_check_in,
    'quoted_nights',   l.quoted_nights,
    'hold_expires_at', l.hold_expires_at,
    'hold_live',       l.hold_expires_at is not null and l.hold_expires_at > now(),
    'history', coalesce((
      select json_agg(json_build_object('d', m.direction, 'b', m.body)
                       order by m.created_at)
      from (select direction, body, created_at from messages
             where channel = p_channel and sender_id = p_sender_id
             order by created_at desc limit 8) m), '[]'::json)
  )
  from (select 1) z
  left join leads l on l.channel = p_channel and l.sender_id = p_sender_id;
$$;

-- ─────────────────────────────────────────────────────────────
-- Save the turn: slots, state, and both sides of the exchange.
--
-- Slots are only ever filled in, never blanked, so a message that says
-- nothing new cannot wipe what the guest already told us. Passing a
-- value explicitly overwrites — that is how a date change works.
--
-- The message inserts are ON CONFLICT DO NOTHING against
-- provider_message_id, so a Meta webhook retry is harmless.
-- ─────────────────────────────────────────────────────────────
create or replace function save_guest_turn(
  p_channel        text,
  p_sender_id      text,
  p_in_message_id  text    default null,
  p_in_body        text    default null,
  p_out_message_id text    default null,
  p_out_body       text    default null,
  p_check_in       text    default null,
  p_nights         text    default null,
  p_pax            text    default null,
  p_occasion       text    default null,
  p_guest_name     text    default null,
  p_phone          text    default null,
  p_conv_state     text    default null,
  p_asked_slot     text    default null,
  p_asked_count    text    default null,
  p_needs_human    boolean default false,
  p_language       text    default null,
  p_quoted_total   text    default null,
  p_offered_check_in text  default null,
  p_place_hold     boolean default false,
  p_property_id    text    default 'bougainvilla'
) returns json
language plpgsql
as $$
declare
  c          pricing_config%rowtype;
  v_in       date;
  v_nights   int;
  v_pax      int;
  v_asked    int;
  v_total    numeric;
  v_out      date;
  v_hold     timestamptz;
  v_status   text;
  v_offer    date;
begin
  select * into c from pricing_config where id = 1;

  begin v_in     := nullif(trim(coalesce(p_check_in,'')),   '')::date;    exception when others then v_in     := null; end;
  begin v_nights := nullif(trim(coalesce(p_nights,'')),     '')::int;     exception when others then v_nights := null; end;
  begin v_pax    := nullif(trim(coalesce(p_pax,'')),        '')::int;     exception when others then v_pax    := null; end;
  begin v_asked  := nullif(trim(coalesce(p_asked_count,'')),'')::int;     exception when others then v_asked  := null; end;
  begin v_total  := nullif(trim(coalesce(p_quoted_total,'')),'')::numeric; exception when others then v_total := null; end;
  begin v_offer  := nullif(trim(coalesce(p_offered_check_in,'')),'')::date; exception when others then v_offer := null; end;

  if v_in is not null then v_out := v_in + coalesce(v_nights, 1); end if;

  -- A hold is not a booking. It expires, and a human confirms it.
  if p_place_hold and v_in is not null then
    v_hold   := now() + make_interval(hours => c.hold_hours);
    v_status := 'held';
  end if;

  insert into leads (channel, sender_id, display_name, phone, booking_status,
                     check_in, check_out, nights, guest_count, occasion,
                     conv_state, asked_slot, asked_count, needs_human,
                     last_language, offered_check_in, quoted_total, quoted_check_in, quoted_nights,
                     hold_expires_at, property_id, last_seen_at)
  values (p_channel, p_sender_id, nullif(p_guest_name,''), nullif(p_phone,''),
          coalesce(v_status, 'enquiry'),
          v_in, v_out, v_nights, v_pax, nullif(p_occasion,''),
          coalesce(nullif(p_conv_state,''), 'NEW'), nullif(p_asked_slot,''),
          coalesce(v_asked, 0), coalesce(p_needs_human,false),
          nullif(p_language,''), v_offer, v_total, case when v_total is not null then v_in end,
          case when v_total is not null then v_nights end,
          v_hold, coalesce(nullif(p_property_id,''),'bougainvilla'), now())
  on conflict (channel, sender_id) do update set
    display_name    = coalesce(excluded.display_name,  leads.display_name),
    phone           = coalesce(excluded.phone,         leads.phone),
    check_in        = coalesce(excluded.check_in,      leads.check_in),
    check_out       = coalesce(excluded.check_out,     leads.check_out),
    nights          = coalesce(excluded.nights,        leads.nights),
    guest_count     = coalesce(excluded.guest_count,   leads.guest_count),
    occasion        = coalesce(excluded.occasion,      leads.occasion),
    conv_state      = coalesce(excluded.conv_state,    leads.conv_state),
    asked_slot      = excluded.asked_slot,
    asked_count     = coalesce(excluded.asked_count,   leads.asked_count),
    needs_human     = excluded.needs_human,
    last_language    = coalesce(excluded.last_language, leads.last_language),
    offered_check_in = excluded.offered_check_in,
    quoted_total    = coalesce(excluded.quoted_total,  leads.quoted_total),
    quoted_check_in = coalesce(excluded.quoted_check_in, leads.quoted_check_in),
    quoted_nights   = coalesce(excluded.quoted_nights, leads.quoted_nights),
    hold_expires_at = coalesce(excluded.hold_expires_at, leads.hold_expires_at),
    booking_status  = case when excluded.booking_status = 'held'
                           then 'held' else leads.booking_status end,
    last_seen_at    = now();

  if nullif(p_in_body, '') is not null then
    insert into messages (channel, sender_id, direction, provider_message_id,
                          body, booking_status, needs_human)
    values (p_channel, p_sender_id, 'in', nullif(p_in_message_id,''),
            p_in_body, p_conv_state, coalesce(p_needs_human,false))
    on conflict (provider_message_id) do nothing;
  end if;

  if nullif(p_out_body, '') is not null then
    insert into messages (channel, sender_id, direction, provider_message_id,
                          body, booking_status, needs_human)
    values (p_channel, p_sender_id, 'out', nullif(p_out_message_id,''),
            p_out_body, p_conv_state, coalesce(p_needs_human,false))
    on conflict (provider_message_id) do nothing;
  end if;

  return json_build_object('ok', true, 'state', p_conv_state,
                           'hold_expires_at', v_hold);
end;
$$;

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


-- ─────────────────────────────────────────────────────────────
-- The agent's availability check.
--
-- Called from n8n as a tool: POST /rest/v1/rpc/check_availability
-- Dates arrive as text because the model may send "" or nonsense; bad
-- input returns an error object rather than raising, so the agent can
-- ask the guest again instead of the run dying.
-- ─────────────────────────────────────────────────────────────
create or replace function check_availability(
  p_check_in    text,
  p_check_out   text default null,
  p_property_id text default 'bougainvilla'
) returns json
language plpgsql
stable
as $$
declare
  v_in     date;
  v_out    date;
  v_confl  json;
  v_free   date;
  v_count  int;
begin
  begin
    v_in := nullif(trim(coalesce(p_check_in,'')), '')::date;
  exception when others then
    return json_build_object('error','bad_check_in',
      'message','Could not read the check-in date. Ask the guest for it as YYYY-MM-DD.');
  end;
  if v_in is null then
    return json_build_object('error','missing_check_in',
      'message','No check-in date given. Ask the guest which dates they want.');
  end if;

  begin
    v_out := nullif(trim(coalesce(p_check_out,'')), '')::date;
  exception when others then v_out := null;
  end;
  -- a single night, or a day visit, if no check-out was given
  if v_out is null or v_out <= v_in then v_out := v_in + 1; end if;

  select count(*), coalesce(json_agg(json_build_object(
           'from', l.check_in, 'to', greatest(l.check_out, l.check_in + 1),
           'held_by', l.display_name, 'status', l.booking_status)), '[]'::json)
    into v_count, v_confl
  from leads l
  where l.check_in is not null
    and (l.booking_status in ('booked','occupied')
         or (l.booking_status = 'held' and l.hold_expires_at > now()))
    and coalesce(l.property_id, 'bougainvilla') = coalesce(p_property_id, 'bougainvilla')
    and v_in < greatest(l.check_out, l.check_in + 1)
    and l.check_in < v_out;

  if v_count = 0 then
    return json_build_object(
      'available', true, 'property_id', p_property_id,
      'check_in', v_in, 'check_out', v_out,
      'nights', (v_out - v_in),
      'message', 'These dates are free.');
  end if;

  -- First date from which the whole stay fits. Plain range overlap:
  -- a candidate [cand, cand+nights) must not intersect any held stay.
  -- generate_series over dates yields timestamptz, hence the ::date cast.
  select min(c.cand) into v_free
  from (select g::date as cand
          from generate_series(v_in, v_in + 180, '1 day') g) c
  where not exists (
    select 1 from leads l
    where l.check_in is not null
      and (l.booking_status in ('booked','occupied')
         or (l.booking_status = 'held' and l.hold_expires_at > now()))
      and coalesce(l.property_id,'bougainvilla') = coalesce(p_property_id,'bougainvilla')
      and c.cand < greatest(l.check_out, l.check_in + 1)
      and l.check_in < c.cand + (v_out - v_in));

  return json_build_object(
    'available', false, 'property_id', p_property_id,
    'check_in', v_in, 'check_out', v_out,
    'nights', (v_out - v_in),
    'conflicts', v_confl,
    'next_available_from', v_free,
    'message', 'Those dates are taken.');
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- One call, everything the dashboard needs
--
-- Conversation stats deliberately EXCLUDE channel 'manual_booking':
-- those rows are the existing booking ledger, not people who messaged.
-- Counting them would report 22 "conversations" that never happened.
--
-- Revenue is priced from the tariff at list, because the historical
-- ledger rows carry no price. Once a stay is quoted through the agent,
-- quoted_total is stored and used instead. revenue_basis says which.
--
-- Profit and break-even appear only when fixed_monthly has been filled
-- in. Until then they are omitted rather than invented.
-- ─────────────────────────────────────────────────────────────
create or replace function dashboard_metrics()
returns json
language sql
stable
as $$
  with
  cfg  as (select * from pricing_config where id = 1),
  chat as (select * from messages where channel <> 'manual_booking'),
  windowed as (
    select
      count(*) filter (where direction = 'in')                       as messages_in,
      count(*) filter (where direction = 'out')                      as messages_out,
      count(*) filter (where created_at >= date_trunc('day', now())) as messages_today,
      count(distinct sender_id)                                      as people
    from chat
  ),
  lead_counts as (
    select
      count(*)                                                          as total_leads,
      count(*) filter (where needs_human)                               as needs_human,
      count(*) filter (where last_seen_at >= now() - interval '7 days') as active_7d,
      count(*) filter (where hold_expires_at > now())                   as live_holds
    from leads where channel <> 'manual_booking'
  ),
  by_channel as (
    select channel, count(distinct sender_id) as n from chat group by channel
  ),
  daily as (
    -- keep the date itself: ordering by the formatted label would sort
    -- "01 Sep" before "22 Aug" and scramble the chart
    select d::date              as day,
           to_char(d, 'DD Mon') as label,
           (select count(*) from chat m
             where m.direction = 'in' and m.created_at::date = d::date) as value
    from generate_series((now() - interval '13 days')::date, now()::date, '1 day') d
  ),
  recent as (
    select l.sender_id, l.display_name, l.lead_stage, l.booking_status,
           l.conv_state, l.needs_human, l.last_seen_at,
           (select body from chat m
             where m.sender_id = l.sender_id and m.direction = 'in'
             order by m.created_at desc limit 1) as last_message
    from leads l where l.channel <> 'manual_booking'
    order by l.last_seen_at desc limit 10
  ),
  -- ── bookings ──
  -- A stay occupies [check_in, check_out); a same-day booking (a day
  -- picnic, where check_in = check_out) still occupies that one day.
  stays as (
    select id, sender_id, display_name, check_in,
           greatest(check_out, check_in + 1) as occ_end,
           booking_status, quoted_total
    from leads
    where check_in is not null
      and booking_status in ('booked','occupied')
  ),
  month_bounds as (
    select date_trunc('month', now())::date                            as m_start,
           (date_trunc('month', now()) + interval '1 month')::date     as m_end
  ),
  -- every night of this month that is sold, with what it earned
  booked_nights as (
    select distinct on (d::date)
           d::date                          as day,
           s.quoted_total,
           greatest(1, s.occ_end - s.check_in) as stay_nights
    from stays s, month_bounds b,
         generate_series(s.check_in, s.occ_end - 1, '1 day') d
    where d >= b.m_start and d < b.m_end
    order by d::date, s.quoted_total nulls last
  ),
  -- every night of this month, sold or not, split into the two buckets
  month_nights as (
    select g::date as day,
           extract(dow from g)::int = any(c.weekend_dows) as is_weekend,
           exists (select 1 from booked_nights bn where bn.day = g::date) as sold
    from month_bounds b, cfg c, generate_series(b.m_start, b.m_end - 1, '1 day') g
  ),
  fill as (
    select
      count(*) filter (where is_weekend)                     as weekend_avail,
      count(*) filter (where is_weekend and sold)            as weekend_sold,
      count(*) filter (where not is_weekend)                 as weekday_avail,
      count(*) filter (where not is_weekend and sold)        as weekday_sold
    from month_nights
  ),
  revenue as (
    select
      coalesce(sum(coalesce(bn.quoted_total / nullif(bn.stay_nights, 0),
                            list_price_for(bn.day))), 0) as amount,
      count(*)                                           as nights,
      bool_or(bn.quoted_total is not null)                as any_quoted
    from booked_nights bn
  ),
  -- the work queue: Mon–Thu nights in the next fortnight with nobody in them
  empty_weekdays as (
    select g::date as day
    from cfg c, generate_series(now()::date, now()::date + 13, '1 day') g
    where not (extract(dow from g)::int = any(c.weekend_dows))
      and not exists (
        select 1 from stays s
        where g::date >= s.check_in and g::date < s.occ_end)
  ),
  economics as (
    select
      c.fixed_monthly,
      c.variable_per_night,
      c.target_profit,
      c.cost_lines,
      (select amount from revenue)                                as revenue,
      (select nights from revenue)                                as nights_sold,
      case when (select nights from revenue) > 0
           then (select amount from revenue) / (select nights from revenue)
      end                                                         as avg_rate
    from cfg c
  ),
  upcoming as (
    select display_name, check_in, occ_end, booking_status
    from stays where occ_end > now()::date
    order by check_in limit 8
  )
  select json_build_object(
    'stats', json_build_object(
      'conversations',  (select people         from windowed),
      'active_leads',   (select active_7d      from lead_counts),
      'messages_today', (select messages_today from windowed),
      'needs_human',    (select needs_human    from lead_counts),
      'live_holds',     (select live_holds     from lead_counts),
      'messages_in',    (select messages_in    from windowed),
      'messages_out',   (select messages_out   from windowed),
      'total_leads',    (select total_leads    from lead_counts)
    ),
    'channels',       (select coalesce(json_object_agg(channel, n), '{}'::json) from by_channel),
    'message_series', json_build_object(
      'labels', (select coalesce(json_agg(label order by day), '[]'::json) from daily),
      'values', (select coalesce(json_agg(value order by day), '[]'::json) from daily)
    ),
    'recent_leads',   (select coalesce(json_agg(recent), '[]'::json) from recent),
    'bookings', json_build_object(
      'total',          (select count(*) from stays),
      'upcoming',       (select count(*) from stays where occ_end > now()::date),
      'nights_this_month', (select nights from revenue),
      'days_in_month',  (select extract(day from (date_trunc('month', now())
                          + interval '1 month - 1 day'))::int),
      'next_free',      (select min(c.cand)::text
                           from (select g::date as cand from generate_series(
                                   now()::date, now()::date + 120, '1 day') g) c
                          where not exists (
                            select 1 from stays s
                            where c.cand >= s.check_in and c.cand < s.occ_end)),
      'list',           (select coalesce(json_agg(json_build_object(
                            'guest',  display_name,
                            'from',   check_in,
                            'to',     occ_end,
                            'status', booking_status)), '[]'::json) from upcoming)
    ),
    -- ── the numbers that decide what to discount ──
    'occupancy', json_build_object(
      'weekend_available', (select weekend_avail from fill),
      'weekend_sold',      (select weekend_sold  from fill),
      'weekend_fill_pct',  (select case when weekend_avail > 0
                              then round(weekend_sold * 100.0 / weekend_avail) end from fill),
      'weekday_available', (select weekday_avail from fill),
      'weekday_sold',      (select weekday_sold  from fill),
      'weekday_fill_pct',  (select case when weekday_avail > 0
                              then round(weekday_sold * 100.0 / weekday_avail) end from fill),
      'empty_weekday_nights_14d',
        (select coalesce(json_agg(json_build_object(
            'date',  day,
            'dow',   to_char(day, 'Dy'),
            'price', (select price from tariff_nightly(day, 1, null, now()::date) limit 1)
          ) order by day), '[]'::json) from empty_weekdays)
    ),
    'economics', (
      select json_build_object(
        'revenue_this_month', round(e.revenue),
        'revenue_basis',      case when (select any_quoted from revenue)
                                   then 'quoted' else 'list_tariff' end,
        'nights_sold',        e.nights_sold,
        'avg_rate',           round(coalesce(e.avg_rate, 0)),
        'fixed_monthly',      e.fixed_monthly,
        'variable_per_night', e.variable_per_night,
        'profit',             case when e.fixed_monthly is not null
                                then round(e.revenue - e.fixed_monthly
                                           - e.variable_per_night * e.nights_sold) end,
        'break_even_nights',  case when e.fixed_monthly is not null
                                    and coalesce(e.avg_rate, 0) > e.variable_per_night
                                then ceil(e.fixed_monthly / (e.avg_rate - e.variable_per_night)) end,
        'nights_to_break_even', case when e.fixed_monthly is not null
                                    and coalesce(e.avg_rate, 0) > e.variable_per_night
                                then greatest(0, ceil(e.fixed_monthly / (e.avg_rate - e.variable_per_night))
                                                 - e.nights_sold) end,
        'target_profit',      e.target_profit,
        'profit_vs_target',   case when e.fixed_monthly is not null and e.target_profit is not null
                                then round(e.revenue - e.fixed_monthly
                                           - e.variable_per_night * e.nights_sold - e.target_profit) end,
        'cost_lines',         e.cost_lines,
        'cost_lines_missing', (select coalesce(json_agg(k order by k), '[]'::json)
                                 from jsonb_each(e.cost_lines) x(k, v)
                                where v = 'null'::jsonb)
      ) from economics e
    ),
    'tariff', (select json_build_object(
        'weekend', c.base_weekend, 'weekday_list', c.base_weekday,
        'weekday_floor', c.weekday_floor, 'base_pax', c.base_pax,
        'ladder', c.ladder) from cfg c)
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
