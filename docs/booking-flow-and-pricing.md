# Booking flow and pricing — plan

Two problems, one root cause and one opportunity.

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
| `HUMAN` | anything odd | hands off |

Because the state is computed from the slots, a guest who opens with
*"villa for 8 people on the 14th, 2 nights"* skips straight to `CHECKING`.
That is the behaviour you actually want, and a transcript-driven agent cannot
do it reliably.

## What the agent may and may not do

**May:** state availability (tool-backed), quote the tariff (formula-backed),
place a 24-hour hold, take name and phone.

**May not:** confirm a booking, take payment, invent a discount beyond the
published ladder, promise anything about amenities or policy.

A hold is not a booking. A human confirms and takes payment. That line stays.

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

**I need your actual numbers for Fixed and Variable.** Everything below is
structurally right but the break-even point moves with them.

### Break-even, nights per month at weekend price

| Fixed / month | V=₹2,000 | V=₹3,000 | V=₹4,000 |
|---|---|---|---|
| ₹1,50,000 | 5.4 | 5.6 | 5.8 |
| ₹2,50,000 | 8.9 | 9.3 | 9.6 |
| ₹3,50,000 | 12.5 | 13.0 | 13.5 |
| ₹4,00,000 | 14.3 | 14.8 | 15.4 |

If fixed cost is ₹3.5L, you need ~13 nights just to stand still. August sold
14. That is the whole story.

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

New tiles, all computable from `leads` plus a small `costs` table:

| Tile | Formula |
|---|---|
| Revenue this month | Σ nights × price paid |
| Weekend fill | booked ÷ available Fri–Sun |
| **Weekday fill** | booked ÷ available Mon–Thu ← *the number to manage* |
| Break-even | fixed ÷ (avg rate − variable) |
| Nights to break-even | break-even − nights sold |
| Profit | revenue − fixed − (variable × nights) |
| Empty weekday nights, next 14 days | the discount ladder's work queue |

The last one is the operational one: it is a list of dates the manager (or a
scheduled n8n post) should be pushing offers on this week.

---

# What I need from you

The plan is complete except for costs. Ballpark monthly figures:

- chef, caretaker, manager, social media — salaries
- electricity, internet, maintenance
- any loan or EMI on the property
- and roughly what a single booked night costs in laundry, gas and consumables

With those I can fill in the break-even, set the discount floor from real
numbers rather than a guess, and give you a monthly target that means
something.

Also worth deciding: **is Friday a weekend or a weekday for pricing?** It sits
on the boundary and moves ~4 nights a month between the two buckets.
