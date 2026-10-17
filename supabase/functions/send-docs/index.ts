// send-docs: emails athletes a copy of what they signed (membership agreement or Waiver and Release Agreement).
// Rows come from public.doc_emails (queued by triggers when they sign, or "Email me a copy" in the app).
// Called by the database (private.doc_email_call) with the internal x-sync-secret; pg_cron 'doc-emails' retries every 30 min.
// Sends through Resend once RESEND_API_KEY and RESEND_FROM (a verified sender, e.g. "Rev Barbell Club <hello@revbbc.com.au>") are set.
// Until then rows stay pending and nothing is lost.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const RESEND = Deno.env.get('RESEND_API_KEY') ?? '';
const FROM = Deno.env.get('RESEND_FROM') ?? '';
const REPLY = Deno.env.get('COACH_EMAIL') ?? 'ant@revbbc.com.au';
const APP = 'https://ant839.github.io/rev-app/';

const esc = (s: string) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const when = (t: string) => new Date(t).toLocaleString('en-AU', { timeZone: 'Australia/Perth', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', hour: 'numeric', minute: '2-digit' });

function render(o: { first: string; title: string; body: string; signedBy: string; signedAt: string; guardian?: string | null; relation?: string | null; media?: boolean | null; kind: string }) {
  const sig = [
    `Signed electronically in the Rev app by ${o.signedBy}${o.guardian ? ` (${o.relation || 'parent or guardian'}, signing for the athlete)` : ''}`,
    `on ${when(o.signedAt)} (Perth time).`,
  ].join(' ');
  const media = o.media == null ? '' : `Photo and video consent: ${o.media ? 'Yes, the Club may use photos and video of me for marketing and social media.' : 'No, please don’t use photos or video of me for marketing or social media.'}`;
  const intro = `Hi ${o.first},\n\nHere’s your copy of the ${o.title} you signed in the Rev app. Please keep this email for your records. You can also view it in the app at any time${o.kind === 'agreement' ? ' (menu, My membership)' : ' (Profile)'}, and you can ask us for a paper copy whenever you like.`;
  const text = `${intro}\n\n----------\n\n${o.title.toUpperCase()}\n\n${o.body}\n\n----------\n\n${sig}${media ? '\n' + media : ''}\n\nAny questions, just reply to this email.\n\nRev Barbell Club and FNDN\nKapcorp Enterprises Pty Ltd\n5/146 Balcatta Road, Balcatta WA\n${REPLY}`;
  const para = (s: string) => esc(s).replace(/\n/g, '<br>');
  const html = `<!doctype html><html><body style="margin:0;background:#f4f4f2;padding:24px 12px;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#1b1b1b">
<div style="max-width:640px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;border:1px solid #e6e6e2">
<div style="background:#0e0e0f;color:#c8f06a;padding:18px 24px;font-weight:700;letter-spacing:.08em">REV BARBELL CLUB</div>
<div style="padding:24px;font-size:15px;line-height:1.6">${para(intro)}</div>
<div style="margin:0 24px;padding:20px;border:1px solid #e6e6e2;border-radius:10px;background:#fafaf8;font-size:14px;line-height:1.6">
<div style="font-weight:700;font-size:16px;margin-bottom:12px">${esc(o.title)}</div>${para(o.body)}
<div style="margin-top:20px;padding-top:14px;border-top:1px solid #e6e6e2;font-size:13px;color:#444">${para(sig)}${media ? '<br>' + para(media) : ''}</div></div>
<div style="padding:20px 24px 24px;font-size:13px;color:#555;line-height:1.6">Any questions, just reply to this email.<br><br>Rev Barbell Club and FNDN<br>Kapcorp Enterprises Pty Ltd<br>5/146 Balcatta Road, Balcatta WA<br><a href="${APP}" style="color:#4a7a00">Open the Rev app</a></div>
</div></body></html>`;
  return { text, html };
}

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const key = req.headers.get('x-sync-secret') || '';
  const { data: ok } = key ? await sb.rpc('records_sync_check', { p_secret: key }) : { data: false };
  if (ok !== true) return new Response('Unauthorised', { status: 401 });

  const { data: rows } = await sb.from('doc_emails').select('*').eq('status', 'pending').order('created_at').limit(25);
  if (!rows?.length) return Response.json({ sent: 0 });
  if (!RESEND || !FROM) {
    await sb.from('doc_emails').update({ error: 'Email not set up yet (RESEND_API_KEY and RESEND_FROM). Will send once it is.' }).in('id', rows.map(r => r.id));
    return Response.json({ sent: 0, waiting: rows.length, reason: 'email not set up' });
  }
  let sent = 0;
  for (const r of rows) {
    try {
      const { data: p } = await sb.from('profiles').select('email,full_name').eq('id', r.profile_id).maybeSingle();
      if (!p?.email) throw new Error('No email address on their profile');
      const first = (p.full_name || 'there').trim().split(/\s+/)[0];
      let doc;
      if (r.kind === 'agreement') {
        const { data: a } = await sb.from('membership_agreements').select('*').eq('id', r.ref_id).maybeSingle();
        if (!a) throw new Error('Signed agreement not found');
        doc = render({ first, kind: 'agreement', title: a.title, body: a.body, signedBy: a.signed_name, signedAt: a.signed_at, guardian: a.guardian_name, relation: a.guardian_relation });
      } else {
        const { data: d } = await sb.from('athlete_details').select('*').eq('profile_id', r.profile_id).maybeSingle();
        const { data: w } = await sb.from('waivers').select('title,body').eq('id', d?.waiver_id ?? r.ref_id).maybeSingle();
        if (!d?.waiver_signed_at || !w) throw new Error('Signed waiver not found');
        doc = render({ first, kind: 'waiver', title: w.title, body: w.body, signedBy: d.waiver_signed_name, signedAt: d.waiver_signed_at, guardian: d.waiver_guardian_name, relation: d.waiver_guardian_relation, media: d.media_consent });
      }
      const title = r.kind === 'agreement' ? 'your membership agreement' : 'your Waiver and Release Agreement';
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST', headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: FROM, to: [p.email], reply_to: REPLY, subject: `Your signed copy of ${title}`, text: doc.text, html: doc.html }),
      });
      if (!res.ok) throw new Error(`Resend ${res.status}: ${(await res.text()).slice(0, 200)}`);
      await sb.from('doc_emails').update({ status: 'sent', sent_at: new Date().toISOString(), error: null, attempts: r.attempts + 1 }).eq('id', r.id);
      sent++;
    } catch (e) {
      const n = r.attempts + 1;
      await sb.from('doc_emails').update({ attempts: n, error: String((e as Error).message || e).slice(0, 300), status: n >= 5 ? 'failed' : 'pending' }).eq('id', r.id);
    }
  }
  return Response.json({ sent, of: rows.length });
});
