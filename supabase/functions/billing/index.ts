// Rev payments through Stripe. One function, three callers:
//  1. Athletes (signed in): 'setup' opens Stripe Checkout to save a card or bank account; 'confirm' saves it after they come back.
//  2. Coaches (signed in): 'charge' runs a membership's next fortnight now, 'retry' retries a failed charge, 'mode' says test or live.
//  3. The database (pg_cron, x-hook-secret): 'tick' charges everyone due today (Wednesdays) and checks on bank debits still processing.
// Card and bank details stay in Stripe. We keep the Stripe customer id, the saved payment method id and brand + last 4 only.
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

// ---- Charge one billing_charges row off-session ----
async function chargeRow(row: any) {
  if (row.amount_cents <= 0) {
    await admin.from("billing_charges").update({ status: "skipped", updated_at: new Date().toISOString() }).eq("id", row.id);
    return { id: row.id, status: "skipped" };
  }
  const { data: cus } = await admin.from("billing_customers").select("*").eq("profile_id", row.profile_id).eq("mode", MODE).maybeSingle();
  const attempts = (row.attempts ?? 0) + 1;
  if (!cus?.pm_id) {
    await admin.from("billing_charges").update({ status: "failed", failure: "No card or bank account saved", attempts, updated_at: new Date().toISOString() }).eq("id", row.id);
    return { id: row.id, status: "failed", failure: "No card or bank account saved" };
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
  return { id: row.id, status, failure };
}

async function refresh(row: any) {
  const r = await stripe(`payment_intents/${row.stripe_pi}`, undefined, "GET");
  if (!r.ok) return null;
  const st = r.data.status;
  const status = st === "succeeded" ? "succeeded" : st === "processing" ? "processing" : st === "canceled" || st === "requires_payment_method" ? "failed" : row.status;
  if (status !== row.status) {
    await admin.from("billing_charges").update({ status, failure: status === "failed" ? (r.data.last_payment_error?.message ?? "Bank debit failed") : null, updated_at: new Date().toISOString() }).eq("id", row.id);
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
          mode: "setup", customer: cus.stripe_customer_id, currency: "aud",   // which methods show (card, BECS direct debit) is set in the Stripe dashboard
          success_url: `${back}${sep}pay=done&sid={CHECKOUT_SESSION_ID}`, cancel_url: `${back}${sep}pay=cancel`,
          metadata: { profile_id: user.id },
        };
        const s = await stripe("checkout/sessions", params);
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
        if (!pm?.id) return json({ error: "No card or bank account was saved" }, 400);
        await stripe(`customers/${cus.stripe_customer_id}`, { invoice_settings: { default_payment_method: pm.id } });
        const summary = pmSummary(pm);
        await admin.from("billing_customers").update({ ...summary, updated_at: new Date().toISOString() }).eq("profile_id", user.id).eq("mode", MODE);
        // try any failed payment again straight away with the new details
        const { data: failed } = await admin.from("billing_charges").select("*").eq("profile_id", user.id).eq("mode", MODE).eq("status", "failed");
        const retried = [];
        for (const row of failed ?? []) retried.push(await chargeRow(row));
        return json({ ok: true, ...summary, retried });
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

      case "retry": {
        if (!isCoach) return json({ error: "Coaches only" }, 403);
        const { data: row } = await admin.from("billing_charges").select("*").eq("id", body.charge_id).single();
        if (!row || row.status !== "failed") return json({ error: "Only failed payments can be retried" }, 400);
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
