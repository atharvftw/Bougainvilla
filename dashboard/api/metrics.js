// Server-side proxy between the dashboard and n8n.
//
// The browser never sees DASHBOARD_API_KEY or the n8n hostname — it just calls
// /api/metrics. This function adds the shared key and forwards to the
// `bougainvilla-dashboard` webhook.
//
// Env (Vercel → Settings → Environment Variables):
//   N8N_DASHBOARD_URL   https://<your-n8n>/webhook/bougainvilla-dashboard
//   DASHBOARD_API_KEY   same value as in n8n

const TIMEOUT_MS = 8000;

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');

  if (req.method !== 'GET') {
    return res.status(405).json({ source: 'unavailable', error: 'method_not_allowed' });
  }

  const url = process.env.N8N_DASHBOARD_URL;
  const key = process.env.DASHBOARD_API_KEY;

  // Not configured yet: tell the page plainly so it shows demo data.
  if (!url || !key) {
    return res.status(200).json({
      source: 'unavailable',
      error: 'not_configured',
      detail: 'Set N8N_DASHBOARD_URL and DASHBOARD_API_KEY in the Vercel project.',
    });
  }

  const control = new AbortController();
  const timer = setTimeout(() => control.abort(), TIMEOUT_MS);

  try {
    const upstream = await fetch(url, {
      method: 'GET',
      headers: { 'x-api-key': key, accept: 'application/json' },
      signal: control.signal,
    });

    if (!upstream.ok) {
      return res.status(200).json({
        source: 'unavailable',
        error: 'upstream_error',
        status: upstream.status,
      });
    }

    const data = await upstream.json();
    return res.status(200).json(data);
  } catch (err) {
    const reason = err.name === 'AbortError' ? 'upstream_timeout' : 'upstream_unreachable';
    return res.status(200).json({ source: 'unavailable', error: reason });
  } finally {
    clearTimeout(timer);
  }
}
