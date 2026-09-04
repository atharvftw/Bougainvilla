// ─── PASTE YOUR APP SECRET HERE ──────────────────────────────────────
//     Meta app → App settings → Basic → App Secret
const META_APP_SECRET = '';
// ─────────────────────────────────────────────────────────────────────
//
// Meta signs every webhook POST with HMAC-SHA256 over the RAW body.
// n8n's Code sandbox exposes neither require() nor a crypto global, so
// SHA-256 and HMAC are implemented here in plain JavaScript. Verified
// byte-identical to Node's createHmac across block-boundary lengths and
// key sizes. Buffer is available in the sandbox and is used for I/O only.

if (!META_APP_SECRET) throw new Error('META_APP_SECRET is empty - refusing to process an unverified Meta webhook');

const K = new Uint32Array([
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
const rotr = (x, n) => ((x >>> n) | (x << (32 - n))) >>> 0;

function sha256(bytes) {
  const H = new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                             0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);
  const l = bytes.length;
  const padded = new Uint8Array(((l + 9) + 63) & ~63);
  padded.set(bytes); padded[l] = 0x80;
  const dv = new DataView(padded.buffer);
  const bits = l * 8;
  dv.setUint32(padded.length - 8, Math.floor(bits / 4294967296));
  dv.setUint32(padded.length - 4, bits >>> 0);
  const w = new Uint32Array(64);
  for (let off = 0; off < padded.length; off += 64) {
    for (let t = 0; t < 16; t++) w[t] = dv.getUint32(off + t * 4);
    for (let t = 16; t < 64; t++) {
      const x = w[t-15], y = w[t-2];
      const s0 = (rotr(x,7) ^ rotr(x,18) ^ (x >>> 3)) >>> 0;
      const s1 = (rotr(y,17) ^ rotr(y,19) ^ (y >>> 10)) >>> 0;
      w[t] = (w[t-16] + s0 + w[t-7] + s1) >>> 0;
    }
    let a=H[0],b=H[1],c=H[2],d=H[3],e=H[4],f=H[5],g=H[6],h=H[7];
    for (let t = 0; t < 64; t++) {
      const S1 = (rotr(e,6) ^ rotr(e,11) ^ rotr(e,25)) >>> 0;
      const ch = ((e & f) ^ (~e & g)) >>> 0;
      const t1 = (h + S1 + ch + K[t] + w[t]) >>> 0;
      const S0 = (rotr(a,2) ^ rotr(a,13) ^ rotr(a,22)) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const t2 = (S0 + maj) >>> 0;
      h=g; g=f; f=e; e=(d+t1)>>>0; d=c; c=b; b=a; a=(t1+t2)>>>0;
    }
    H[0]=(H[0]+a)>>>0; H[1]=(H[1]+b)>>>0; H[2]=(H[2]+c)>>>0; H[3]=(H[3]+d)>>>0;
    H[4]=(H[4]+e)>>>0; H[5]=(H[5]+f)>>>0; H[6]=(H[6]+g)>>>0; H[7]=(H[7]+h)>>>0;
  }
  const out = new Uint8Array(32), odv = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) odv.setUint32(i * 4, H[i]);
  return out;
}

function hmacHex(keyBytes, msgBytes) {
  let k = keyBytes;
  if (k.length > 64) k = sha256(k);
  const key = new Uint8Array(64); key.set(k);
  const ipad = new Uint8Array(64 + msgBytes.length);
  const opad = new Uint8Array(64 + 32);
  for (let i = 0; i < 64; i++) { ipad[i] = key[i] ^ 0x36; opad[i] = key[i] ^ 0x5c; }
  ipad.set(msgBytes, 64);
  opad.set(sha256(ipad), 64);
  let s = '';
  for (const b of sha256(opad)) s += b.toString(16).padStart(2, '0');
  return s;
}

const item = $input.first();
const headers = item.json.headers || {};
const received = String(headers['x-hub-signature-256'] || '');

const b64 = item.binary && item.binary.data && item.binary.data.data;
const raw = b64 ? Buffer.from(b64, 'base64') : null;
const rawStr = raw ? raw.toString('utf8') : '';

const secretBytes = new Uint8Array(Buffer.from(META_APP_SECRET, 'utf8'));
const sig = b => 'sha256=' + hmacHex(secretBytes, new Uint8Array(b));

// Hypothesis A: the raw body is byte-exact (what Meta signed)
const overRaw = raw ? sig(raw) : null;

// Hypothesis B: n8n re-serialised the JSON, so the bytes differ
let overReserialised = null;
try { overReserialised = sig(Buffer.from(JSON.stringify(JSON.parse(rawStr)), 'utf8')); } catch (e) {}

return [{ json: {
  '1_secret_length':        META_APP_SECRET.length,
  '1_secret_is_32_hex':     /^[a-f0-9]{32}$/i.test(META_APP_SECRET),
  '1_secret_has_whitespace': META_APP_SECRET !== META_APP_SECRET.trim(),

  '2_signature_header_present': Boolean(received),
  '2_received':             received,

  '3_computed_over_raw':    overRaw,
  '3_MATCHES_RAW':          received === overRaw,

  '4_computed_over_reserialised': overReserialised,
  '4_MATCHES_RESERIALISED': received === overReserialised,

  '5_raw_body_length':      raw ? raw.length : 0,
  '5_raw_body_preview':     rawStr.slice(0, 300),
  '5_header_names':         Object.keys(headers),
} }];