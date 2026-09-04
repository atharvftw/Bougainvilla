#!/usr/bin/env node
/**
 * Push n8n/bougainvilla-crm.workflow.json into a live n8n — without wiping
 * the values you pasted in by hand.
 *
 *   export N8N_URL=https://n8n.veloit.in
 *   export N8N_API_KEY=...            # n8n → Settings → n8n API
 *   node scripts/n8n-deploy.mjs --dry-run     # show what would change
 *   node scripts/n8n-deploy.mjs               # apply
 *
 * The repo copy is a blank template: app secrets, verify tokens, credential
 * selections and your Supabase project URL are deliberately not in it. This
 * script reads those back off the live workflow and re-injects them, so
 * deploying never costs you a round of re-pasting.
 *
 * Nothing secret is printed, and nothing is written in --dry-run.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const WORKFLOW = join(HERE, '..', 'n8n', 'bougainvilla-crm.workflow.json');

const BASE = (process.env.N8N_URL || '').replace(/\/+$/, '');
const KEY = process.env.N8N_API_KEY || '';
const DRY = process.argv.includes('--dry-run');
const ACTIVATE = !process.argv.includes('--no-activate');

process.on('uncaughtException', (e) => {
  console.error('\n✗ ' + e.message + (e.friendly ? '\n  ' + e.friendly : ''));
  process.exit(1);
});
process.on('unhandledRejection', (e) => {
  const err = e instanceof Error ? e : new Error(String(e));
  console.error('\n✗ ' + err.message + (err.friendly ? '\n  ' + err.friendly : ''));
  process.exit(1);
});

if (!BASE || !KEY) {
  console.error('Set N8N_URL and N8N_API_KEY first.\n' +
    '  export N8N_URL=https://n8n.veloit.in\n' +
    '  export N8N_API_KEY=...   # n8n → Settings → n8n API');
  process.exit(1);
}

// n8n rejects a PUT carrying read-only fields — additionalProperties is false.
const WRITABLE = ['name', 'nodes', 'connections', 'settings'];

// Placeholders the repo ships; a live value always wins over these.
const PLACEHOLDER = /YOUR_PROJECT|PASTE_INSTAGRAM_BUSINESS_ID|REPLACE_ME|CRED_[A-Z_]+/;

async function api(path, init = {}) {
  let res;
  try {
    res = await fetch(BASE + path, {
      ...init,
      headers: { 'X-N8N-API-KEY': KEY, 'content-type': 'application/json', ...(init.headers || {}) },
    });
  } catch (e) {
    const err = new Error(`Cannot reach ${BASE} — ${e.cause?.code || e.message}`);
    err.friendly = 'Check N8N_URL, and that the instance is up and reachable from here.';
    throw err;
  }
  if (res.status === 401 || res.status === 403) {
    const err = new Error(`n8n rejected the API key (HTTP ${res.status}).`);
    err.friendly = 'Create one at n8n → Settings → n8n API, and export it as N8N_API_KEY.';
    throw err;
  }
  const text = await res.text();
  let body; try { body = JSON.parse(text); } catch { body = text; }
  if (!res.ok) {
    throw new Error(`${init.method || 'GET'} ${path} → ${res.status}\n` +
      (typeof body === 'string' ? body : JSON.stringify(body, null, 2)));
  }
  return body;
}

/** `const NAME = 'value';` pairs from a Code node, value non-empty. */
function constants(code) {
  const out = {};
  const re = /const\s+([A-Z][A-Z0-9_]*)\s*=\s*'([^']*)'\s*;/g;
  let m;
  while ((m = re.exec(code || ''))) if (m[2]) out[m[1]] = m[2];
  return out;
}

function injectConstant(code, name, value) {
  return code.replace(
    new RegExp(`(const\\s+${name}\\s*=\\s*')([^']*)('\\s*;)`),
    (_, a, _old, c) => a + value + c);
}

function die(msg, hint) {
  console.error('\n✗ ' + msg + (hint ? '\n  ' + hint : ''));
  process.exit(1);
}

const local = JSON.parse(readFileSync(WORKFLOW, 'utf8'));

console.log(`n8n      ${BASE}`);
const list = await api('/api/v1/workflows?limit=250');
const items = list.data || list;
const matches = items.filter(w => w.name === local.name);
if (matches.length > 1) {
  const wanted = process.env.N8N_WORKFLOW_ID;
  if (!wanted) {
    die(`${matches.length} workflows are named "${local.name}" — refusing to guess.`,
      'Pick one and re-run with N8N_WORKFLOW_ID set:\n  ' +
      matches.map(w => `${w.id}  (${w.active ? 'active' : 'inactive'})`).join('\n  '));
  }
}
const live = process.env.N8N_WORKFLOW_ID
  ? items.find(w => w.id === process.env.N8N_WORKFLOW_ID)
  : matches[0];
if (!live) {
  console.error(`\nNo workflow named "${local.name}" on that instance.\n` +
    `Found: ${items.map(w => `${w.name} (${w.id})`).join(', ') || '(none)'}\n` +
    `Set N8N_WORKFLOW_ID to target one by id.\n` +
    `Import the JSON once through the UI first, then this script can update it.`);
  process.exit(1);
}
const full = await api(`/api/v1/workflows/${live.id}`);
console.log(`workflow ${full.name} (${full.id}) — ${full.active ? 'active' : 'inactive'}\n`);

// ── carry hand-entered state forward ────────────────────────────────
const liveByName = new Map(full.nodes.map(n => [n.name, n]));
const carried = [];

for (const node of local.nodes) {
  const was = liveByName.get(node.name);
  if (!was) continue;

  // credential selections
  if (was.credentials && Object.keys(was.credentials).length) {
    const repoIds = JSON.stringify(node.credentials || {});
    if (PLACEHOLDER.test(repoIds) || !node.credentials) {
      node.credentials = was.credentials;
      carried.push(`${node.name}: credential`);
    }
  }

  // secrets pasted into Code-node constants
  if (node.parameters?.jsCode && was.parameters?.jsCode) {
    for (const [name, value] of Object.entries(constants(was.parameters.jsCode))) {
      const mine = constants(node.parameters.jsCode)[name];
      if (!mine) {
        node.parameters.jsCode = injectConstant(node.parameters.jsCode, name, value);
        carried.push(`${node.name}: ${name}`);
      }
    }
  }

  // URLs still carrying a placeholder
  for (const field of ['url', 'jsonBody', 'body']) {
    const mine = node.parameters?.[field], theirs = was.parameters?.[field];
    if (typeof mine === 'string' && typeof theirs === 'string' &&
        PLACEHOLDER.test(mine) && !PLACEHOLDER.test(theirs)) {
      node.parameters[field] = theirs;
      carried.push(`${node.name}: ${field}`);
    }
  }
}

console.log(carried.length
  ? `Carried over from the live workflow:\n${carried.map(c => '  · ' + c).join('\n')}`
  : 'Nothing to carry over.');

// anything still unset would break at runtime — say so loudly
const unresolved = [];
for (const node of local.nodes) {
  const blob = JSON.stringify({ p: node.parameters, c: node.credentials });
  if (PLACEHOLDER.test(blob)) unresolved.push(node.name);
  for (const [k, v] of Object.entries(constants(node.parameters?.jsCode || ''))) void k, v;
  if (node.parameters?.jsCode) {
    const blanks = [...(node.parameters.jsCode.matchAll(/const\s+([A-Z][A-Z0-9_]*)\s*=\s*''\s*;/g))];
    for (const b of blanks) unresolved.push(`${node.name}: ${b[1]} is empty`);
  }
}
if (unresolved.length) {
  console.log(`\n⚠  Still needs a value in the n8n UI after deploy:\n` +
    [...new Set(unresolved)].map(u => '  · ' + u).join('\n'));
}

const payload = Object.fromEntries(WRITABLE.map(k => [k, local[k] ?? full[k]]));
payload.settings = local.settings || full.settings || {};

const disabled = local.nodes.filter(n => n.disabled).map(n => n.name);
console.log(`\n${local.nodes.length} nodes, ${disabled.length} disabled` +
  (disabled.length ? `: ${disabled.join(', ')}` : ''));

if (DRY) {
  console.log('\n--dry-run: nothing written.');
  process.exit(0);
}

await api(`/api/v1/workflows/${full.id}`, { method: 'PUT', body: JSON.stringify(payload) });
console.log('\n✓ Workflow updated.');

if (ACTIVATE && full.active) {
  try {
    await api(`/api/v1/workflows/${full.id}/activate`, { method: 'POST' });
    console.log('✓ Re-activated.');
  } catch (e) {
    console.log('! Could not re-activate — do it in the UI.\n  ' + e.message.split('\n')[0]);
  }
}
