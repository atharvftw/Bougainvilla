# Deploying workflow changes without re-pasting secrets

`scripts/n8n-deploy.mjs` pushes `n8n/bougainvilla-crm.workflow.json` into your
live n8n over the public API — and carries your hand-entered values forward, so
a deploy never costs you a round of re-pasting app secrets and re-picking
credentials.

## Why you run it, not Claude

The Claude session that builds these changes sits behind an egress proxy that
refuses outbound connections to `n8n.veloit.in` — the same wall that blocks
Meta's and Vercel's domains from it. An n8n API key given to that session would
be unusable. Run it from your own machine, where the instance is reachable.

## Setup, once

1. **n8n → Settings → n8n API → Create an API key.** Copy it.
2. In a terminal at the repo root:

```bash
export N8N_URL=https://n8n.veloit.in
export N8N_API_KEY=n8n_api_...
```

Put those in your shell profile if you want them to stick. The key is a full
admin credential for the instance — treat it like a password and keep it out
of the repo.

## Use

```bash
git pull
node scripts/n8n-deploy.mjs --dry-run   # show what would change, write nothing
node scripts/n8n-deploy.mjs             # apply
```

It prints what it carried over, warns about anything still unset, and
re-activates the workflow if it was active before.

`--no-activate` leaves it deactivated.

## What it carries forward

Read off the live workflow and re-injected into the repo version:

| Kept | Why it isn't in the repo |
|---|---|
| `META_APP_SECRET`, `META_VERIFY_TOKEN`, `DASHBOARD_API_KEY` | secrets — the repo copy is a blank template |
| Credential selections on every node | the credential IDs are yours, not portable |
| Your Supabase project URL | the repo ships `YOUR_PROJECT` |
| `INSTAGRAM_BUSINESS_ID` in the send URL | the repo ships a placeholder |

Everything else — node logic, prompts, connections, which tools are enabled —
comes from the repo. That is the point: the repo is the source of truth for
behaviour, your instance is the source of truth for secrets.

## Notes

- The workflow must exist in n8n already, matched **by name**
  (`Bougainvilla CRM — AI Booking & Operations`). Import the JSON through the
  UI once; after that this script updates it.
- Re-importing creates a *second* workflow rather than replacing the first. If
  two share the name the script refuses to guess and lists their ids; pick one
  with `export N8N_WORKFLOW_ID=...`. Archive the stale copy so only one is
  active — two active copies means two replies to every DM.
- n8n's API rejects a PUT carrying read-only fields (`id`, `active`,
  `versionId`, …) with a 400. The script sends only `name`, `nodes`,
  `connections`, `settings`.
- Nothing secret is printed, and `--dry-run` writes nothing.
- Verified against a mock instance enforcing the same read-only contract:
  secrets, credentials and URLs preserved; updated prompt deployed; workflow
  re-activated; wrong key, unreachable host and missing env each fail with a
  readable message rather than a stack trace.
