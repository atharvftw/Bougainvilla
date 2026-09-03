#!/usr/bin/env node
// Validates the Bougainvilla credentials before you wire anything up.
//
//   cp .env.example .env   # fill it in
//   node scripts/check-creds.mjs
//
// Optional:
//   node scripts/check-creds.mjs --refresh   refresh the Instagram token
//   N8N_BASE=https://your-n8n node scripts/check-creds.mjs   also test the webhook
//
// Nothing is sent anywhere except Meta, Sarvam, and your own n8n. Secrets are
// never printed in full.

import { readFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';

const GRAPH  = process.env.GRAPH_HOST  || 'https://graph.instagram.com';
const SARVAM = process.env.SARVAM_HOST || 'https://api.sarvam.ai';
const REFRESH = process.argv.includes('--refresh');

// ── .env loader (real values live here, never in git) ──
function loadEnv(file = '.env') {
  try {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
      if (!m) continue;
      const v = m[2].trim().replace(/^["']|["']$/g, '');
      if (v && !process.env[m[1]]) process.env[m[1]] = v;
    }
  } catch { /* env vars may be set directly */ }
}
loadEnv();

let failed = 0, warned = 0;
const pass = (m, d) => console.log(`  \x1b[32m✓\x1b[0m ${m}${d ? `  \x1b[2m${d}\x1b[0m` : ''}`);
const fail = (m, d) => { failed++; console.log(`  \x1b[31m✗\x1b[0m ${m}${d ? `\n      \x1b[2m${d}\x1b[0m` : ''}`); };
const warn = (m, d) => { warned++; console.log(`  \x1b[33m!\x1b[0m ${m}${d ? `\n      \x1b[2m${d}\x1b[0m` : ''}`); };
const head = (t) => console.log(`\n\x1b[1m${t}\x1b[0m`);
const mask = (s) => !s ? '(unset)' : s.length <= 12 ? '*'.repeat(s.length) : `${s.slice(0,4)}…${s.slice(-4)} (${s.length} chars)`;

async function getJSON(url) {
  const res = await fetch(url, { headers: { accept: 'application/json' } });
  let body; try { body = await res.json(); } catch { body = {}; }
  return { ok: res.ok, status: res.status, body };
}

// ── 1 · presence and shape ──
head('1 · Values present');
const env = {};
for (const k of ['META_APP_SECRET','META_ACCESS_TOKEN','INSTAGRAM_BUSINESS_ID','META_VERIFY_TOKEN','SARVAM_API_KEY']) {
  env[k] = (process.env[k] || '').trim();
  if (env[k]) pass(k, mask(env[k])); else fail(k, 'missing from .env');
}
if (env.META_APP_SECRET && !/^[a-f0-9]{32}$/i.test(env.META_APP_SECRET))
  warn('META_APP_SECRET is not 32 hex characters', 'App secrets normally are — check you copied the secret, not the App ID.');
if (env.META_ACCESS_TOKEN && env.META_ACCESS_TOKEN.length < 50)
  warn('META_ACCESS_TOKEN looks short', 'Instagram tokens are long. Did you copy the whole value?');
if (env.INSTAGRAM_BUSINESS_ID && !/^\d+$/.test(env.INSTAGRAM_BUSINESS_ID))
  fail('INSTAGRAM_BUSINESS_ID is not numeric', 'This must be the numeric account ID, not the @handle.');
if (failed) { console.log('\nFix the above first — later checks need these.\n'); process.exit(1); }

// ── 2 · token works, and belongs to the right account ──
head('2 · Instagram token');
const me = await getJSON(`${GRAPH}/me?fields=id,username,account_type&access_token=${encodeURIComponent(env.META_ACCESS_TOKEN)}`);
if (!me.ok) {
  const e = me.body.error || {};
  fail(`Token rejected (HTTP ${me.status})`, e.message || JSON.stringify(me.body));
  if (/expired|session/i.test(e.message || ''))
    console.log('      \x1b[2mAn expired token cannot be refreshed — redo "Add account" in the app.\x1b[0m');
} else {
  pass('Token is valid', `@${me.body.username || '?'}`);

  if (String(me.body.id) === env.INSTAGRAM_BUSINESS_ID) {
    pass('INSTAGRAM_BUSINESS_ID matches the token', me.body.id);
  } else {
    fail('INSTAGRAM_BUSINESS_ID does not match the token',
         `token belongs to ${me.body.id} (@${me.body.username}), but .env says ${env.INSTAGRAM_BUSINESS_ID}`);
  }

  const t = me.body.account_type;
  if (t === 'BUSINESS' || t === 'MEDIA_CREATOR') pass('Account is Professional', t);
  else warn(`Account type is ${t || 'unknown'}`, 'Messaging needs a Business or Creator account.');

  // Did you connect the villa account, or your personal one by mistake?
  console.log(`\n      \x1b[2mConnected as @${me.body.username} — is that the villa account, not your personal one?\x1b[0m`);
}

// ── 3 · app secret ──
head('3 · App secret');
if (me.ok) {
  const proof = createHmac('sha256', env.META_APP_SECRET).update(env.META_ACCESS_TOKEN).digest('hex');
  const r = await getJSON(`${GRAPH}/me?fields=id&access_token=${encodeURIComponent(env.META_ACCESS_TOKEN)}&appsecret_proof=${proof}`);
  if (r.ok) pass('Accepted with appsecret_proof');
  else if (/appsecret|proof/i.test(r.body.error?.message || ''))
    fail('App secret is wrong', r.body.error.message);
  else warn('Could not confirm the app secret', 'The call failed for an unrelated reason; verification is inconclusive.');
} else {
  warn('Skipped', 'needs a working token');
}

// ── 4 · Sarvam ──
head('4 · Sarvam API key');
try {
  const res = await fetch(`${SARVAM}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'api-subscription-key': env.SARVAM_API_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'sarvam-m', messages: [{ role: 'user', content: 'ping' }], max_tokens: 1 }),
  });
  if (res.ok) pass('Key accepted');
  else if (res.status === 401 || res.status === 403) fail(`Key rejected (HTTP ${res.status})`);
  else warn(`Unexpected HTTP ${res.status}`, `${(await res.text()).slice(0, 200)}\n      The key may be fine but the model id wrong — check dashboard.sarvam.ai.`);
} catch (e) { warn('Could not reach Sarvam', e.message); }

// ── 5 · n8n webhook (optional) ──
if (process.env.N8N_BASE) {
  head('5 · n8n webhook');
  const url = `${process.env.N8N_BASE.replace(/\/$/, '')}/webhook/bougainvilla-instagram`;
  try {
    const good = await fetch(`${url}?hub.mode=subscribe&hub.verify_token=${encodeURIComponent(env.META_VERIFY_TOKEN)}&hub.challenge=probe123`);
    const text = (await good.text()).trim();
    if (good.ok && text === 'probe123') pass('Verification handshake echoes the challenge');
    else fail(`Handshake failed (HTTP ${good.status})`, `expected "probe123", got "${text.slice(0,80)}"`);

    const bad = await fetch(`${url}?hub.mode=subscribe&hub.verify_token=definitely-wrong&hub.challenge=x`);
    if (bad.status === 403) pass('Wrong verify token is rejected with 403');
    else fail(`Wrong verify token returned HTTP ${bad.status}`, 'expected 403');

    const unsigned = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"entry":[]}' });
    if (!unsigned.ok) pass('Unsigned POST is rejected', `HTTP ${unsigned.status}`);
    else fail('Unsigned POST was ACCEPTED', 'META_APP_SECRET is not reaching the Code node. Anyone could inject fake bookings — fix before going live.');
  } catch (e) { fail('Could not reach n8n', e.message); }
} else {
  head('5 · n8n webhook');
  console.log('  \x1b[2m- skipped. Re-run with N8N_BASE=https://your-n8n once it is deployed.\x1b[0m');
}

// ── refresh ──
if (REFRESH && me.ok) {
  head('Refreshing Instagram token');
  const r = await getJSON(`${GRAPH}/refresh_access_token?grant_type=ig_refresh_token&access_token=${encodeURIComponent(env.META_ACCESS_TOKEN)}`);
  if (r.ok && r.body.access_token) {
    const days = Math.round((r.body.expires_in || 0) / 86400);
    pass(`New token issued, valid ~${days} days`);
    console.log(`\n\x1b[1mPut this in META_ACCESS_TOKEN (n8n and .env):\x1b[0m\n${r.body.access_token}\n`);
  } else {
    fail('Refresh failed', r.body.error?.message || JSON.stringify(r.body));
    console.log('      \x1b[2mTokens must be at least 24h old to refresh, and expired ones never can be.\x1b[0m');
  }
}

// ── summary ──
console.log('');
if (failed) console.log(`\x1b[31m${failed} failed\x1b[0m${warned ? `, \x1b[33m${warned} warning(s)\x1b[0m` : ''}\n`);
else if (warned) console.log(`\x1b[32mAll checks passed\x1b[0m with \x1b[33m${warned} warning(s)\x1b[0m\n`);
else console.log('\x1b[32mAll checks passed.\x1b[0m\n');
process.exit(failed ? 1 : 0);
