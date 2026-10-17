// Rev payments through Stripe. One function, three callers:
//  1. Athletes (signed in): 'setup' opens Stripe Checkout to save a card; 'confirm' saves it after they come back.
//     'join' does the same for someone buying a membership in the app; 'confirm' then creates the membership (billing = app).
//  2. Coaches (signed in): 'charge' runs a membership's next fortnight now, 'mode' says test or live.
//     'retry' runs a failed charge again (coaches, or the athlete for their own payment once the money is in their account).
//  Missed payments are emailed (Resend, when RESEND_API_KEY is set) to the coach, and to the athlete once RESEND_FROM is a verified sender.
//  3. The database (pg_cron, x-hook-secret): 'tick' charges everyone due today (Wednesdays) and checks on payments still processing.
// Card details stay in Stripe. We keep the Stripe customer id, the saved payment method id and brand + last 4 only.
import { createClient } from "npm:@supabase/supabase-js@2";

const SK = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const MODE = SK.startsWith("sk_live_") ? "live" : "test";
const HOOK_SECRET = "df4daeda854558c251a2d45e077f3cdd1993dc5ef33bbcda";
const APP = "https://ant839.github.io/rev-app/";
const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const perthToday = () => new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10);

// ---- Stripe REST (form encoded, nested keys) ----
function enc(obj: Record<string, unknown>, pre = "", out: string[] = []): string[] {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = pre ? `${pre}[${k}]` : k;
    if (Array.isArray(v)) v.forEach((x, i) => typeof x === "object" ? enc(x as Record<string, unknown>, `${key}[${i}]`, out) : out.push(`${encodeURIComponent(`${key}[${i}]`)}=${encodeURIComponent(String(x))}`));
    else if (typeof v === "object") enc(v as Record<string, unknown>, key, out);
    else out.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`);
  }
  return out;
}
async function stripe(path: string, params?: Record<string, unknown>, method = "POST", idem?: string) {
  const headers: Record<string, string> = { Authorization: `Bearer ${SK}`, "Content-Type": "application/x-www-form-urlencoded" };
  if (idem) headers["Idempotency-Key"] = idem;
  const body = method === "GET" ? undefined : enc(params ?? {}).join("&");
  const q = method === "GET" && params ? "?" + enc(params).join("&") : "";
  const r = await fetch(`https://api.stripe.com/v1/${path}${q}`, { method, headers, body });
  const data = await r.json();
  return { ok: r.ok, data };
}

// ---- Saved payment method summary ----
function pmSummary(pm: any) {
  if (!pm) return {};
  if (pm.type === "card") return { pm_id: pm.id, pm_type: "card", pm_brand: pm.card?.brand ?? "card", pm_last4: pm.card?.last4 ?? null, pm_exp: pm.card ? `${String(pm.card.exp_month).padStart(2, "0")}/${String(pm.card.exp_year).slice(-2)}` : null };
  if (pm.type === "au_becs_debit") return { pm_id: pm.id, pm_type: "au_becs_debit", pm_brand: "Bank account" + (pm.au_becs_debit?.bsb_number ? ` (BSB ${pm.au_becs_debit.bsb_number})` : ""), pm_last4: pm.au_becs_debit?.last4 ?? null, pm_exp: null };
  return { pm_id: pm.id, pm_type: pm.type, pm_brand: pm.type, pm_last4: null, pm_exp: null };
}

async function customerFor(profileId: string, email: string | null, name: string | null) {
  const { data: row } = await admin.from("billing_customers").select("*").eq("profile_id", profileId).eq("mode", MODE).maybeSingle();
  if (row) return row;
  let cus: any = null;
  if (MODE === "live" && email) {   // Gymdesk already created most athletes in Stripe: reuse them so their saved card carries over
    const found = await stripe("customers", { email, limit: 1 }, "GET");
    cus = found.data?.data?.[0] ?? null;
  }
  if (!cus) {
    const made = await stripe("customers", { email: email ?? undefined, name: name ?? undefined, metadata: { profile_id: profileId, source: "rev-app" } });
    if (!made.ok) throw new Error(made.data?.error?.message ?? "Could not create the Stripe customer");
    cus = made.data;
  }
  const pmId = cus.invoice_settings?.default_payment_method;
  let summary = {};
  if (pmId) { const pm = await stripe(`payment_methods/${pmId}`, undefined, "GET"); if (pm.ok) summary = pmSummary(pm.data); }
  const rec = { profile_id: profileId, mode: MODE, stripe_customer_id: cus.id, ...summary, updated_at: new Date().toISOString() };
  await admin.from("billing_customers").upsert(rec);
  return rec as any;
}

// ---- Cards only on Stripe's page ----
// Checkout no longer takes payment_method_types, so we keep our own payment method configuration with only cards
// (plus Apple Pay / Google Pay, which are cards) switched on, and pass it to Checkout.
const KEEP = new Set(["card", "apple_pay", "google_pay"]);
let PMC: string | null = null;
async function cardsOnly(): Promise<{ id: string | null; on: string[]; error?: string }> {
  const list = await stripe("payment_method_configurations", { limit: 100 }, "GET");
  let cfg = (list.data?.data ?? []).find((c: any) => c.name === "Rev app cards only" && c.active);
  if (!cfg) {
    const made = await stripe("payment_method_configurations", { name: "Rev app cards only", card: { display_preference: { preference: "on" } } });
    if (!made.ok) return { id: null, on: [], error: made.data?.error?.message };
    cfg = made.data;
  }
  const isOn = (k: string) => cfg[k]?.display_preference?.value === "on";
  const off: Record<string, unknown> = {};
  for (const k of Object.keys(cfg)) if (cfg[k]?.display_preference && isOn(k) && !KEEP.has(k)) off[k] = { display_preference: { preference: "off" } };
  if (!isOn("card")) off.card = { display_preference: { preference: "on" } };
  if (Object.keys(off).length) {
    const up = await stripe(`payment_method_configurations/${cfg.id}`, off);
    if (!up.ok) return { id: cfg.id, on: [], error: up.data?.error?.message };
    cfg = up.data;
  }
  PMC = cfg.id;
  return { id: cfg.id, on: Object.keys(cfg).filter((k) => isOn(k)) };
}

// ---- Joining in the app ----
const addDays = (d: string, n: number) => { const x = new Date(d + "T00:00:00Z"); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const isoDow = (d: string) => { const w = new Date(d + "T00:00:00Z").getUTCDay(); return w === 0 ? 7 : w; };
const wedOf = (d: string) => addDays(d, 3 - isoDow(d));   // Wednesday of that Monday to Sunday week
const dayLong = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-AU", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
async function joinCheck(userClient: any, planId: string, start: string) {
  const { data: me, error } = await userClient.rpc("my_membership");
  if (error) return { error: error.message };
  if (!me?.can_join) return { error: me?.current ? "You already have a membership" : "Joining in the app isn't open for your account yet. Talk to Ant." };
  const plan = (me.plans ?? []).find((p: any) => p.id === planId);
  if (!plan) return { error: "That membership can't be bought in the app" };
  const today = perthToday();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || start < today || start > addDays(today, 14)) return { error: "Pick a start date in the next 2 weeks" };
  return { plan };
}

// ---- Missed payment emails (Resend) ----
const RESEND = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("RESEND_FROM") ?? "";                      // e.g. "Rev Barbell Club <payments@revbbc.com.au>" once the domain is verified
const COACH_EMAIL = Deno.env.get("COACH_EMAIL") ?? "ant@revbbc.com.au";
const money = (c: number) => "$" + (c / 100).toFixed(c % 100 ? 2 : 0);
const dShort = (d: string) => new Date(d + "T00:00:00Z").toLocaleDateString("en-AU", { day: "numeric", month: "short", timeZone: "UTC" });
const escH = (t: string) => t.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
async function sendMail(to: string, subject: string, text: string, html: string) {
  if (!RESEND || !to) return false;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST", headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM || "Rev App <onboarding@resend.dev>", to: [to], subject, text, html }),
  });
  if (!r.ok) console.warn("email failed", to, await r.text());
  return r.ok;
}
function mailBox(title: string, lines: string[], btn: string, url: string) {
  return `<div style="font-family:-apple-system,Segoe UI,Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#111">
    <div style="font-weight:800;letter-spacing:.08em;font-size:13px;margin-bottom:18px">REV BARBELL CLUB</div>
    <div style="border-left:4px solid #e5484d;padding:4px 0 4px 14px;margin-bottom:16px"><div style="font-size:18px;font-weight:700">${escH(title)}</div></div>
    ${lines.map((l) => `<p style="font-size:15px;line-height:1.5;margin:0 0 12px">${escH(l)}</p>`).join("")}
    <a href="${url}" style="display:inline-block;background:#e5484d;color:#fff;text-decoration:none;font-weight:600;padding:12px 20px;border-radius:10px;margin-top:6px">${escH(btn)}</a></div>`;
}
async function emailMissed(row: any, failure: string | null) {
  if (!RESEND || row.notified_at) return;   // one email per missed payment, not one per retry
  const { data: p } = await admin.from("profiles").select("full_name,email").eq("id", row.profile_id).single();
  const name = p?.full_name || p?.email || "An athlete", first = (p?.full_name || "").split(" ")[0] || "there";
  const amt = money(row.amount_cents), per = `${dShort(row.period_start)} to ${dShort(row.period_end)}`;
  const test = MODE === "test" ? "[TEST] " : "";
  const reason = failure ? `Reason from the bank: ${failure}` : "";
  let sent = await sendMail(COACH_EMAIL, `${test}Missed payment: ${name} ${amt}`,
    `${name}'s ${amt} membership payment for ${per} didn't go through. ${reason}\n\nThey've been notified in the app. Open REV Admin: ${APP}admin.html#memberships`,
    mailBox(`Missed payment: ${name}`, [`${amt} for ${per} didn't go through.`, reason, "They've been sent a notification in the app with a button to run the payment again."].filter(Boolean), "Open REV Admin", `${APP}admin.html#memberships`));
  if (FROM && p?.email) {
    sent = (await sendMail(p.email, `${test}Your Rev membership payment didn't go through`,
      `Hi ${first},\n\nYour ${amt} membership payment for ${per} didn't go through. Usually it's just not enough in the account on the day. Once it's sorted, open the Rev app and tap Run payment again, or update your card under Payments.\n\n${APP}#pay\n\nAnt - Coach`,
      mailBox("Your payment didn't go through", [`Hi ${first},`, `Your ${amt} membership payment for ${per} didn't go through. Usually it's just not enough in the account on the day.`, "Once it's sorted, open the Rev app and tap Run payment again, or update your card under Payments.", "Ant - Coach"], "Open Payments", `${APP}#pay`))) || sent;
  }
  if (sent) await admin.from("billing_charges").update({ notified_at: new Date().toISOString() }).eq("id", row.id);
}

// ---- Charge one billing_charges row off-session ----
async function chargeRow(row: any) {
  if (row.amount_cents <= 0) {
    await admin.from("billing_charges").update({ status: "skipped", updated_at: new Date().toISOString() }).eq("id", row.id);
    return { id: row.id, status: "skipped" };
  }
  const { data: cus } = await admin.from("billing_customers").select("*").eq("profile_id", row.profile_id).eq("mode", MODE).maybeSingle();
  const attempts = (row.attempts ?? 0) + 1;
  if (!cus?.pm_id) {
    await admin.from("billing_charges").update({ status: "failed", failure: "No card saved", attempts, updated_at: new Date().toISOString() }).eq("id", row.id);
    await emailMissed(row, "No card saved");
    return { id: row.id, status: "failed", failure: "No card saved" };
  }
  const r = await stripe("payment_intents", {
    amount: row.amount_cents, currency: "aud", customer: cus.stripe_customer_id, payment_method: cus.pm_id,
    automatic_payment_methods: { enabled: true, allow_redirects: "never" }, off_session: true, confirm: true,
    description: row.description ?? "Rev Barbell Club membership",
    metadata: { charge_id: row.id, profile_id: row.profile_id, period: `${row.period_start} to ${row.period_end}` },
  }, "POST", `${row.id}-${attempts}`);
  const pi = r.ok ? r.data : r.data?.error?.payment_intent;
  const st = pi?.status;
  const status = st === "succeeded" ? "succeeded" : st === "processing" ? "processing" : "failed";
  const failure = status === "failed" ? (r.data?.error?.message ?? pi?.last_payment_error?.message ?? "Payment failed") : null;
  await admin.from("billing_charges").update({ status, stripe_pi: pi?.id ?? row.stripe_pi, failure, attempts, updated_at: new Date().toISOString() }).eq("id", row.id);
  if (status === "failed") await emailMissed(row, failure);
  return { id: row.id, status, failure };
}

async function refresh(row: any) {
  const r = await stripe(`payment_intents/${row.stripe_pi}`, undefined, "GET");
  if (!r.ok) return null;
  const st = r.data.status;
  const status = st === "succeeded" ? "succeeded" : st === "processing" ? "processing" : st === "canceled" || st === "requires_payment_method" ? "failed" : row.status;
  if (status !== row.status) {
    await admin.from("billing_charges").update({ status, failure: status === "failed" ? (r.data.last_payment_error?.message ?? "Payment failed") : null, updated_at: new Date().toISOString() }).eq("id", row.id);
  }
  return status;
}

async function tick(day: string) {
  const { data: due, error } = await admin.rpc("billing_due", { p_date: day });
  if (error) throw new Error(error.message);
  if (due?.length) {
    await admin.from("billing_charges").upsert(due.map((d: any) => ({ ...d, mode: MODE })), { onConflict: "membership_id,period_start,mode", ignoreDuplicates: true });
  }
  const { data: pend } = await admin.from("billing_charges").select("*").eq("mode", MODE).eq("status", "pending").lte("bill_date", day);
  const charged = [];
  for (const row of pend ?? []) charged.push(await chargeRow(row));
  const { data: proc } = await admin.from("billing_charges").select("*").eq("mode", MODE).eq("status", "processing").not("stripe_pi", "is", null);
  let refreshed = 0;
  for (const row of proc ?? []) { await refresh(row); refreshed++; }
  return { day, mode: MODE, due: due?.length ?? 0, charged, refreshed };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!SK) return json({ error: "Stripe isn't connected yet (STRIPE_SECRET_KEY missing)" }, 500);
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }

  // Database schedule
  if (req.headers.get("x-hook-secret") === HOOK_SECRET) {
    if (body.action === "probe" && MODE === "test") {   // check which methods Checkout offers
      const cfg = await cardsOnly();
      const c = await stripe("customers", { name: "Rev app probe", metadata: { source: "rev-app-selftest" } });
      const s = await stripe("checkout/sessions", { mode: "setup", customer: c.data.id, currency: "aud", payment_method_configuration: cfg.id ?? undefined, success_url: `${APP}?pay=done&sid={CHECKOUT_SESSION_ID}`, cancel_url: `${APP}?pay=cancel`, custom_text: { submit: { message: "Joining Barbell Club Gold: $65 per week, billed fortnightly." } } });
      if (s.ok) await stripe(`checkout/sessions/${s.data.id}/expire`, {});
      return json({ cfg, ok: s.ok, methods: s.data?.payment_method_types ?? null, error: s.data?.error?.message ?? null, email: !!RESEND, from: FROM || null });
    }
    try { return json(await tick(body.day ?? perthToday())); } catch (e) { return json({ error: String(e) }, 500); }
  }

  // Signed-in users
  const auth = req.headers.get("Authorization") ?? "";
  const userClient = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Please sign in" }, 401);
  const { data: me } = await admin.from("profiles").select("id,full_name,email,role").eq("id", user.id).single();
  const isCoach = me?.role === "coach";

  try {
    switch (body.action) {
      case "mode":
        return json({ mode: MODE });

      case "setup": {
        const back = String(body.return_url || APP);
        if (!back.startsWith(APP)) return json({ error: "Bad return address" }, 400);
        const cus = await customerFor(user.id, me?.email ?? user.email ?? null, me?.full_name ?? null);
        const sep = back.includes("?") ? "&" : "?";
        const params: Record<string, unknown> = {
          mode: "setup", customer: cus.stripe_customer_id, currency: "aud", payment_method_configuration: PMC ?? (await cardsOnly()).id ?? undefined,   // cards only (Ant, 16 Oct)
          success_url: `${back}${sep}pay=done&sid={CHECKOUT_SESSION_ID}`, cancel_url: `${back}${sep}pay=cancel`,
          metadata: { profile_id: user.id },
        };
        const s = await stripe("checkout/sessions", params);
        if (!s.ok) return json({ error: s.data?.error?.message ?? "Stripe error" }, 400);
        return json({ url: s.data.url, mode: MODE });
      }

      case "join": {   // athlete buying a membership: save a card in Stripe, then 'confirm' creates the membership
        const back = String(body.return_url || APP);
        if (!back.startsWith(APP)) return json({ error: "Bad return address" }, 400);
        const chk: any = await joinCheck(userClient, String(body.plan_id || ""), String(body.start_date || ""));
        if (chk.error) return json({ error: chk.error }, 400);
        const cus = await customerFor(user.id, me?.email ?? user.email ?? null, me?.full_name ?? null);
        const anchor = wedOf(body.start_date), wk = Number(chk.plan.weekly);
        const first = anchor <= perthToday() ? "today" : dayLong(anchor);
        const sep = back.includes("?") ? "&" : "?";
        const s = await stripe("checkout/sessions", {
          mode: "setup", customer: cus.stripe_customer_id, currency: "aud", payment_method_configuration: PMC ?? (await cardsOnly()).id ?? undefined,
          success_url: `${back}${sep}pay=done&sid={CHECKOUT_SESSION_ID}`, cancel_url: `${back}${sep}pay=cancel`,
          metadata: { profile_id: user.id, join_plan: chk.plan.id, join_start: body.start_date },
          custom_text: { submit: { message: `Joining ${chk.plan.name}: ${money(wk * 100)} per week, billed fortnightly. Starts ${dayLong(body.start_date)}. First payment ${money(wk * 200)} ${first === "today" ? "taken today" : "on " + first}.` } },
        });
        if (!s.ok) return json({ error: s.data?.error?.message ?? "Stripe error" }, 400);
        return json({ url: s.data.url, mode: MODE });
      }

      case "confirm": {
        const sid = String(body.sid || "");
        const s = await stripe(`checkout/sessions/${sid}`, { expand: ["setup_intent.payment_method"] }, "GET");
        if (!s.ok) return json({ error: s.data?.error?.message ?? "Couldn't find that setup" }, 400);
        const { data: cus } = await admin.from("billing_customers").select("*").eq("profile_id", user.id).eq("mode", MODE).maybeSingle();
        if (!cus || s.data.customer !== cus.stripe_customer_id) return json({ error: "That setup belongs to someone else" }, 403);
        const pm = s.data.setup_intent?.payment_method;
        if (!pm?.id) return json({ error: "No card was saved" }, 400);
        await stripe(`customers/${cus.stripe_customer_id}`, { invoice_settings: { default_payment_method: pm.id } });
        const summary = pmSummary(pm);
        await admin.from("billing_customers").update({ ...summary, updated_at: new Date().toISOString() }).eq("profile_id", user.id).eq("mode", MODE);
        // try any failed payment again straight away with the new details
        const { data: failed } = await admin.from("billing_charges").select("*").eq("profile_id", user.id).eq("mode", MODE).eq("status", "failed");
        const retried = [];
        for (const row of failed ?? []) retried.push(await chargeRow(row));
        // buying a membership: create it now (once; reloading the page won't make a second one)
        let joined: any = null;
        const md = s.data.metadata ?? {};
        if (md.join_plan && md.profile_id === user.id) {
          const chk: any = await joinCheck(userClient, md.join_plan, md.join_start);
          if (!chk.error) {
            const anchor = wedOf(md.join_start);
            const ins = await admin.from("memberships").insert({ profile_id: user.id, plan_id: md.join_plan, start_date: md.join_start, billing: "app",
              bill_anchor: anchor, created_by: user.id, notes: "Joined in the app" }).select().single();
            if (ins.error) return json({ error: ins.error.message }, 400);
            const { data: beta } = await admin.from("groups").select("id").ilike("name", "beta testers").maybeSingle();   // bookings are still in beta
            if (beta) await admin.from("group_members").upsert({ group_id: beta.id, profile_id: user.id }, { onConflict: "group_id,profile_id", ignoreDuplicates: true });
            joined = { plan: chk.plan.name, start: md.join_start, weekly: chk.plan.weekly, first_payment: anchor };
            if (anchor <= perthToday()) {   // their first Wednesday has already been: take the first fortnight now
              const { data: due } = await admin.rpc("billing_due", { p_date: anchor });
              const row = (due ?? []).find((d: any) => d.membership_id === ins.data.id);
              if (row) {
                const c = await admin.from("billing_charges").upsert({ ...row, mode: MODE }, { onConflict: "membership_id,period_start,mode" }).select().single();
                if (!c.error) joined.charge = await chargeRow(c.data);
              }
            }
          } else if (chk.error !== "You already have a membership") return json({ error: chk.error }, 400);
        }
        return json({ ok: true, ...summary, retried, joined });
      }

      case "charge": {   // coach: run a membership's next fortnight now
        if (!isCoach) return json({ error: "Coaches only" }, 403);
        const { data: next, error } = await userClient.rpc("billing_next", { p_membership: body.membership_id });
        if (error) return json({ error: error.message }, 400);
        if (!next || next.ended || !next.bill_date) return json({ error: "Nothing to charge for this membership" }, 400);
        const { data: due } = await admin.rpc("billing_due", { p_date: next.bill_date });
        const row = (due ?? []).find((d: any) => d.membership_id === body.membership_id);
        if (!row) return json({ error: "Nothing due for that fortnight" }, 400);
        const ins = await admin.from("billing_charges").upsert({ ...row, mode: MODE }, { onConflict: "membership_id,period_start,mode" }).select().single();
        if (ins.error) return json({ error: ins.error.message }, 400);
        if (ins.data.status === "succeeded" || ins.data.status === "processing") return json({ error: "That fortnight is already paid" }, 400);
        return json(await chargeRow(ins.data));
      }

      case "retry": {   // coach, or the athlete running their own missed payment again
        const { data: row } = await admin.from("billing_charges").select("*").eq("id", body.charge_id).maybeSingle();
        if (!row || (!isCoach && row.profile_id !== user.id)) return json({ error: "Couldn't find that payment" }, 404);
        if (row.status !== "failed") return json({ error: row.status === "succeeded" ? "That payment has already gone through" : "Only missed payments can be run again" }, 400);
        if (!isCoach && Date.now() - new Date(row.updated_at).getTime() < 30e3) return json({ error: "Give it 30 seconds and try again" }, 429);
        return json(await chargeRow(row));
      }

      case "selftest": {   // coach, test mode only: prove charging works with Stripe's test cards. Leaves only a test customer in the sandbox.
        if (!isCoach) return json({ error: "Coaches only" }, 403);
        if (MODE !== "test") return json({ error: "Self test only runs in test mode" }, 400);
        const out: Record<string, unknown> = {};
        const cus = await stripe("customers", { name: "Rev app self test", metadata: { source: "rev-app-selftest" } });
        if (!cus.ok) return json({ error: cus.data?.error?.message }, 400);
        const run = async (testPm: string, cents: number) => {
          const pm = await stripe(`payment_methods/${testPm}/attach`, { customer: cus.data.id });
          if (!pm.ok) return { error: pm.data?.error?.message };
          const r = await stripe("payment_intents", { amount: cents, currency: "aud", customer: cus.data.id, payment_method: pm.data.id, automatic_payment_methods: { enabled: true, allow_redirects: "never" }, off_session: true, confirm: true, description: "Rev app self test" });
          const pi = r.ok ? r.data : r.data?.error?.payment_intent;
          return { status: pi?.status ?? null, error: r.ok ? null : r.data?.error?.message, summary: pmSummary(pm.data) };
        };
        out.good_card = await run("pm_card_visa", 6000);
        out.declined_card = await run("pm_card_chargeCustomerFail", 6000);
        const s = await stripe("checkout/sessions", { mode: "setup", customer: cus.data.id, currency: "aud", success_url: `${APP}?pay=done&sid={CHECKOUT_SESSION_ID}`, cancel_url: `${APP}?pay=cancel` });
        out.checkout = s.ok ? "ok" : s.data?.error?.message;
        if (s.ok) {
          const full = await stripe(`checkout/sessions/${s.data.id}`, undefined, "GET");
          out.checkout_methods = full.data?.payment_method_types ?? null;
          await stripe(`checkout/sessions/${s.data.id}/expire`, {});
        }
        return json(out);
      }

      case "tick": {   // coach: run today's (or a given day's) charge run by hand, for testing
        if (!isCoach) return json({ error: "Coaches only" }, 403);
        return json(await tick(body.day ?? perthToday()));
      }
    }
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
