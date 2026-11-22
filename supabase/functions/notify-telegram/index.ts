// Supabase Edge Function: send a Telegram message for every new booking.
//
// Triggered by a Database Webhook (Database → Webhooks) on INSERT into
// public.bookings, with an HTTP header `x-webhook-secret: <WEBHOOK_SECRET>`.
//
// Secrets (never in the frontend):
//   supabase secrets set TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... WEBHOOK_SECRET=...
// Deploy:
//   supabase functions deploy notify-telegram --no-verify-jwt

const TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN');
const CHAT_ID = Deno.env.get('TELEGRAM_CHAT_ID');
const SECRET = Deno.env.get('WEBHOOK_SECRET');

const escape = (value: unknown) =>
  String(value ?? '—').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  // Fail closed: without configured secrets the function refuses to run.
  if (!SECRET || !TOKEN || !CHAT_ID) return json({ error: 'Function is not configured' }, 500);
  if (req.headers.get('x-webhook-secret') !== SECRET) return json({ error: 'Unauthorized' }, 401);

  let payload: { type?: string; table?: string; record?: Record<string, unknown> };
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'Invalid JSON' }, 400);
  }
  if (payload.type !== 'INSERT' || payload.table !== 'bookings' || !payload.record) {
    return json({ ignored: true });
  }

  const b = payload.record;
  const text = [
    '🧭 <b>New booking request</b>',
    '',
    `<b>Ref:</b> ${escape(b.reference)}`,
    `<b>Tour:</b> ${escape(b.tour_title)}`,
    `<b>Date:</b> ${escape(b.travel_date)} · <b>Travellers:</b> ${escape(b.travelers)}`,
    `<b>Name:</b> ${escape(b.full_name)} (${escape(b.country)})`,
    `<b>Email:</b> ${escape(b.email)}`,
    `<b>Phone:</b> ${escape(b.phone)}`,
    b.message ? `\n<i>${escape(b.message)}</i>` : '',
  ].join('\n');

  const res = await fetch(`https://api.telegram.org/bot${TOKEN}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: CHAT_ID, text, parse_mode: 'HTML', disable_web_page_preview: true }),
  });

  if (!res.ok) {
    console.error('Telegram API error', res.status, await res.text());
    return json({ error: 'Telegram request failed' }, 502);
  }
  return json({ ok: true });
});
