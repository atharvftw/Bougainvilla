# Booking flow and pricing

Two problems, one root cause and one opportunity.

> **Status: built.** The state machine, the pricing engine and the dashboard
> tiles below are implemented and tested — `supabase/schema.sql`, the eleven
> Instagram nodes in `n8n/bougainvilla-crm.workflow.json`, and
> `dashboard/index.html`. What is still missing is your real cost figures; see
> [What I need from you](#what-i-need-from-you) at the end.

1. The agent asks for dates and guest count, gets told, then asks again.
2. Weekends are 79–92% full. Weekdays are 17–18% full. All the money is Mon–Thu.

---

# Part 1 · Why the agent loops

`Guest Conversation Memory` is n8n's in-RAM window buffer. It holds a
transcript and nothing else — no structured state, and it clears on restart.
So on every message the agent re-derives "what do I know about this guest?"
from raw chat text, inside a prompt that also contains its rules, its schema
and its tool description. A small model drops things. It asks again.

**Nothing is being saved between messages.** That is the whole bug. More
prompt engineering will not fix it.

## The fix: slots in the database, questions in code

Keep the guest's answers as **columns**, not conversation. Decide the next
question in **code**. Use the model for the two things it is actually good at:
reading a messy human sentence, and phrasing a warm reply.

```
message in
   ↓
load slots for this sender from Supabase        ← deterministic
   ↓
AI EXTRACT: what does this message add?         ← model, narrow job
   ↓
merge + save slots                              ← deterministic
   ↓
pick next action from the state table           ← deterministic
   ↓
AI COMPOSE: say this, warmly, in their language ← model, narrow job
   ↓
reply + save
```

The model never decides *what* to ask. It is told what to ask.

Implemented as `get_guest_state()` → `Extract Guest Details` →
`Merge Guest Slots` → `quote_stay()` → `Decide Next Question` →
`Compose Guest Reply` → `save_guest_turn()`.

Every one of the four network calls continues on error and every step has a
deterministic fallback, so a dead model or a dead database still produces the
right question rather than silence.

## The six slots

| # | Slot | Type | Required for |
|---|---|---|---|
| 1 | `check_in` | date | availability |
| 2 | `nights` | int (default 1) | availability |
| 3 | `pax` | int | quote |
| 4 | `occasion` | text, optional | never blocks — used for upsell |
| 5 | `guest_name` | text | hold |
| 6 | `phone` | text | hold |

## The question ladder — fixed order, no improvisation

Ask for the **first empty slot**. One question per message, two at most.

| State | Condition | The agent says |
|---|---|---|
| `NEW` | no dates | "Which dates were you looking at?" |
| `DATES` | dates, no pax | "How many guests will you be?" |
| `CHECKING` | dates + pax | *(calls `check_availability`)* |
| `UNAVAILABLE` | dates taken | "Those are taken — I have {next_free} free. Does that work?" |
| `QUOTED` | available + priced | "{dates} is free for {pax} — ₹{total} for {nights} night(s). Shall I hold it?" |
| `NEEDS_NAME` | said yes, no name | "Lovely. What name should I put it under?" |
| `NEEDS_PHONE` | name, no phone | "And a number the caretaker can reach you on?" |
| `HOLD_PLACED` | all slots | "Held for 24 hours. Our team will call to confirm and take payment." |
| `HELD` | a live hold, nothing changed | acknowledges instead of re-announcing |
| `HUMAN` | anything odd | hands off |

Two things the first draft of this table got wrong, both caught by running
conversations through it:

- **Agreement has to be sticky.** A guest who says "yes", then gives their
  name, has not stopped agreeing — but a table that re-checks `agrees` on
  every turn falls back to `QUOTED` and starts quoting at them again. That is
  the original bug, rebuilt. Once past `QUOTED`, the state stays past it.
- **"Yes" after `UNAVAILABLE` means the date we offered.** Without somewhere
  to keep that date the conversation dead-ends, so `leads.offered_check_in`
  holds it and a bare yes adopts it.

Asking the same slot three times escalates to a human. A loop is a failure,
not persistence.

Because the state is computed from the slots, a guest who opens with
*"villa for 8 people on the 14th, 2 nights"* skips straight to `CHECKING`.
That is the behaviour you actually want, and a transcript-driven agent cannot
do it reliably.

## What the agent may and may not do

**May:** state availability (tool-backed), quote the tariff (formula-backed),
place a 24-hour hold, take name and phone.

**May not:** confirm a booking, take payment, invent a discount beyond the
published ladder, promise anything about amenities or policy.

A hold is not a booking. A human confirms and takes payment. That line stays —
and a live hold blocks the dates for everyone else while it lasts, so two
guests can never be quoted the same night.

Enforced twice, not just asked for: the model is told to add no facts, and
`Finalize Reply` then checks that every number of 1,000 or more in the reply
also appears in the sentence we handed it. Invent a discount and the reply is
discarded for the plain template.

---

# Part 2 · The money

## The equation

```
Profit  =  Revenue − Fixed − (Variable × nights sold)

Revenue =  (weekend nights × 30,000)
         + (weekday nights × weekday price)
         + (extra pax above 10 × per-person rate × nights)

Fixed   =  chef + caretaker + manager + social media + electricity + internet
           + maintenance + any EMI            ← per month, paid whether or not
                                                anyone stays

Variable=  laundry + gas + consumables + deep clean + welcome kit
                                                ← per booked night only
```

### The costs, as supplied

| Line | ₹ / month |
|---|---|
| Social media | 18,000 |
| Caretaker | 15,000 |
| Manager | 25,000 |
| Electricity | 30,000 |
| **Supplied total** | **88,000** |
| Chef | *not supplied* |
| Internet | *not supplied* |
| Maintenance | *not supplied* |
| Loan / EMI | *not supplied* |

Four of eight lines are real; the rest are null in `pricing_config.cost_lines`,
and **null is not zero**. Every profit number below is therefore an upper
bound, and the dashboard says so on its face rather than quietly flattering
the month.

Variable cost is held at ₹3,000 a night — laundry, gas, consumables, a deep
clean. That one is an assumption too; it was not supplied.

> If the chef is paid per booking rather than monthly, that is not a missing
> fixed cost at all — it belongs in `variable_per_night`. Worth deciding which,
> because it changes the discount floor.

### Break-even is the surprise

On ₹88,000 of known fixed cost, a weekend night contributes ₹27,000 after its
variable cost. So:

**The villa covers its known monthly costs in four weekend nights.**

Everything after that is contribution, which reframes the whole discount
argument. You are not discounting to survive the month — the month is already
paid for by the second weekend. You are discounting to convert nights that
would otherwise earn nothing at all.

At the ₹17,000 floor a weekday night still contributes ₹14,000, so even the
deepest discount pays a full month's known costs in seven nights.

## Where you actually are

Weekend = Fri/Sat/Sun. Weekday = Mon–Thu (the block you want filled).

| | nights available | booked | fill |
|---|---|---|---|
| **August weekends** | 14 | 11 | **79%** |
| **August weekdays** | 17 | 3 | **18%** |

August weekday bookings: Tue 11th, Wed 19th, Tue 25th. Revenue at list price
₹4,14,000. **14 weekday nights went empty.**

July, from your description (4 weekends + 15 nights total):

| reading | weekend | weekday | revenue |
|---|---|---|---|
| weekend = 2 nights | 8 (62%) | 7 (39%) | ₹4,36,000 |
| weekend = 3 nights | 12 (92%) | 3 (17%) | ₹4,44,000 |

Both readings say the same thing: **weekends are nearly sold out, weekdays are
nearly empty.** Two months running.

> Your ledger has 14 August rows; you said 11. Worth reconciling before these
> numbers go in front of anyone.

## Why discounting weekdays is close to free money

An empty night earns **zero**. It does not become cheaper by staying empty —
the chef, caretaker and manager are paid either way.

At V = ₹3,000 per booked night:

| weekday price | discount | contributes |
|---|---|---|
| ₹28,000 | 0% | ₹25,000 |
| ₹21,000 | 25% | ₹18,000 |
| ₹18,000 | 36% | ₹15,000 |
| **₹14,000** | **50%** | **₹11,000** |
| ₹9,000 | 68% | ₹6,000 |

**A half-price weekday night still contributes ₹11,000 more than an empty
one.** That is the entire case for a discount ladder.

### What it is worth on August's numbers

| | revenue | change |
|---|---|---|
| actual (11 WE + 3 WD) | ₹4,14,000 | — |
| +4 weekday at 30% off | ₹4,92,400 | **+19%** |
| +7 weekday at 30% off | ₹5,51,200 | **+33%** |
| +10 weekday at 40% off | ₹5,82,000 | **+41%** |
| +14 weekday at 50% off | ₹6,10,000 | **+47%** |

Even the most aggressive column beats holding the line on price, because the
alternative is not "sell at ₹28,000" — the alternative is an empty villa.

---

# Part 2b · The reference month

**15 nights sold: every weekend night, plus one weekday.** This is the shape
you described, and it is the number to beat.

October 2026 has 14 weekend nights and 17 weekday nights, so 15 nights means
all 14 weekends plus one Mon–Thu.

| How the weekends sell | Weekend revenue | + 1 weekday | Profit |
|---|---|---|---|
| Fri + Sat, Sunday booked separately | 4,20,000 | at list 28,000 | **3,15,000** |
| Fri + Sat, Sunday booked separately | 4,20,000 | at 22,500 | 3,09,500 |
| Fri–Mon stays, Sunday at the add-on | 3,48,000 | at list 28,000 | 2,43,000 |
| **Fri–Mon stays, Sunday at the add-on** | **3,48,000** | **at 22,500** | **2,37,500** |

All four are `revenue − 88,000 fixed − 45,000 variable`.

**The reference is set to ₹2,37,500** — the bottom corner, deliberately. A
target you beat is worth more than one you admire, and the top corner assumes
Sundays sell as their own full-price bookings, which is the optimistic read.

It lives in `pricing_config.target_profit`, and the dashboard shows the month
running against it.

Add the four missing cost lines and it moves down, one rupee for one rupee:

| Extra fixed / month | Reference profit |
|---|---|
| 0 | 2,37,500 |
| 50,000 | 1,87,500 |
| 1,00,000 | 1,37,500 |
| 1,50,000 | 87,500 |

## Next month, priced

October: 14 weekend nights, 17 weekday. Weekends have run 79% full, so assume
11 sell — three full Fri–Mon weekends and one Fri+Sat, ₹2,76,000.

| Weekday nights sold | At | Revenue | Profit | vs reference |
|---|---|---|---|---|
| 0 | — | 2,76,000 | 1,55,000 | −82,500 |
| 2 | 25,000 · 15–21d | 3,26,000 | 1,99,000 | −38,500 |
| **4** | **22,500 · 8–14d** | **3,66,000** | **2,33,000** | **−4,500** |
| 6 | 22,500 · 8–14d | 4,11,000 | 2,72,000 | **+34,500** |
| 8 | 21,000 · midweek3 | 4,44,000 | 2,99,000 | **+61,500** |
| 10 | 19,500 · 4–7d | 4,71,000 | 3,20,000 | **+82,500** |
| 12 | 17,000 · floor | 4,80,000 | 3,23,000 | **+85,500** |

**Six weekday nights beats the reference. Ten roughly doubles the profit over
selling weekends alone.** Note the last row: dropping from 19,500 to the
17,000 floor buys two more nights and only ₹3,000 more profit — that is the
floor doing its job, and the evidence for not going below it.

The operational target for October: **sell 6–8 Mon–Thu nights.** The dashboard's
empty-weekday-nights queue is the list to work from.

---

# Part 3 · Dynamic weekday pricing

## Rule zero: never discount a weekend

Weekends run 79–92% full. A discount there is pure margin donated to guests
who would have paid list. **Weekends stay ₹30,000. No exceptions, no codes.**

## The ladder — by how close the date is

Weekdays only (Mon–Thu). Price falls as an empty night approaches, because an
unsold night is worth nothing at midnight.

| Days until check-in | Weekday price | Off |
|---|---|---|
| 22+ | ₹28,000 | 0% |
| 15–21 | ₹25,000 | 10% |
| 8–14 | ₹22,500 | 20% |
| 4–7 | ₹19,500 | 30% |
| 0–3 | ₹17,000 | 40% |

**Floor: ₹17,000.** Never lower, whatever the algorithm says. Below that you
train the market to wait, and cheap guests cost more in wear than they pay.

## Stacked offers, for the shape of the gap

- **Three-night midweek (Mon–Thu): 25% off regardless of lead time.**
  Fills three nights in one booking, one changeover, one deep clean. The
  cheapest revenue you will ever earn.
- **Sunday-night add-on to a weekend booking: ₹12,000.** They are already
  there; the room is already dirty. Nearly pure contribution.
- **Corporate / offsite Mon–Wed:** quote at the 20% tier and hold it. A
  repeating booking is worth more than one deep discount.

## What the agent is allowed to offer

The ladder is a **formula in the database**, not a judgement call. The agent
reads a price and states it. It never negotiates, never rounds down, never
invents a code. If a guest pushes for more, that is `needs_human`.

---

# Part 4 · Dashboard additions

Built, and live in the page:

| Tile | Formula |
|---|---|
| Revenue this month | Σ nights × price paid |
| Weekend fill | booked ÷ available Fri–Sun |
| **Weekday fill** | booked ÷ available Mon–Thu ← *the number to manage* |
| Break-even | fixed ÷ (avg rate − variable) |
| Nights to break-even | break-even − nights sold |
| Profit | revenue − fixed − (variable × nights) |
| **Against target** | profit − `target_profit` ← *the reference month* |
| Empty weekday nights, next 14 days | the discount ladder's work queue |

Plus a banner naming any cost line still missing, so nobody reads a profit
figure as final when four of the eight inputs are null.

The last one is the operational one: a list of dates the manager (or a
scheduled n8n post) should be pushing offers on this week, each with the price
the ladder currently asks.

Profit, break-even and against-target stay blank until
`pricing_config.fixed_monthly` and `target_profit` have real numbers in them.
The page says what is missing rather than showing a confident wrong figure.

---

# Settled, and still open

**Friday is a weekend.** `weekend_dows = {5,6,0}` — the default, nothing to
change.

**Four cost lines are in:** social media, caretaker, manager, electricity.

**Four are not,** and until they arrive every profit figure in this document is
an upper bound. Each is one number in `pricing_config`:

- chef, internet, maintenance, EMI — and, for the chef, whether it is paid
  monthly (fixed) or per booking (variable, which changes the discount floor)
- the real variable cost of a booked night, currently assumed ₹3,000

Then: `update pricing_config set fixed_monthly = <new total> where id = 1;`
and the reference and every tile move with it.
