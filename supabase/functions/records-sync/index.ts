// records-sync: pulls current senior records into club_records.
//   wa    <- Weightlifting WA       https://www.wwa.org.au/Statistics/Records          (HTML table)
//   aus   <- Australian WF          https://www.awf.com.au/competition/statistics/records (HTML table)
//   world <- Wikipedia's IWF list   (iwf.sport blocks automated requests with a Cloudflare check)
// Called daily by pg_cron and by the coach's "Refresh" button (rpc records_sync_now), both with the x-sync-secret header.
// A source is only applied when it parses cleanly, so a site redesign can never wipe the board.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CATS: Record<string, string[]> = {
  male: ['60', '65', '70', '75', '85', '95', '110', '+110'],
  female: ['49', '53', '57', '61', '69', '77', '86', '+86'],
};
const BROWSER_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36';
const WIKI_UA = 'RevBarbellRecords/1.0 (https://ant839.github.io/rev-app/; ant@revbbc.com.au)';
type Row = { sex: string; category: string; lift: string; weight_kg: number; lifter_name: string; set_on: string; competition?: string | null; nation?: string | null; source_url?: string | null; note?: string | null };

const ent = (s: string) => s.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&#39;|&#039;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n));
const txt = (s: string) => ent(s.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
const iso = (d: Date) => d.toISOString().slice(0, 10);
const perthToday = () => iso(new Date(Date.now() + 8 * 3600e3));

// d/m/yyyy, falling back to m/d/yyyy when d/m would be in the future (the AWF list mixes both)
function auDate(s: string): string | null {
  const m = s.trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/); if (!m) { const i = s.trim().match(/^(\d{4})-(\d{2})-(\d{2})$/); return i ? i[0] : null; }
  const mk = (d: number, mo: number, y: number) => (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) ? `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}` : null;
  const a = mk(+m[1], +m[2], +m[3]), b = mk(+m[2], +m[1], +m[3]), today = perthToday();
  if (a && a <= today) return a; if (b && b <= today) return b; return a || b;
}
function catOf(label: string): { sex: string; category: string } | null {
  const m = label.trim().toUpperCase().match(/^([FM])\s*(\d+)\s*(\+?)$/); if (!m) return null;
  const sex = m[1] === 'F' ? 'female' : 'male', category = (m[3] ? '+' : '') + m[2];
  return CATS[sex].includes(category) ? { sex, category } : null;
}

// AWF and WWA share the same record module: one table per class, rows SN / CJ / TOTAL with kg, name, date, competition
async function australian(url: string): Promise<{ rows: Row[]; cells: number }> {
  const r = await fetch(url, { headers: { 'User-Agent': BROWSER_UA, 'Accept': 'text/html', 'Accept-Language': 'en-AU,en;q=0.9' } });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const html = await r.text();
  const rows: Row[] = []; let cells = 0;
  for (const chunk of html.split(/class="moduleAWF RecordRankings"/).slice(1)) {
    const th = chunk.match(/<th[^>]*>([\s\S]*?)<\/th>/); const c = th && catOf(txt(th[1])); if (!c) continue;
    for (const tr of chunk.split('</table>')[0].matchAll(/<tr>([\s\S]*?)<\/tr>/g)) {
      const tds = [...tr[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map(x => x[1]); if (tds.length < 4) continue;
      const a = tds[0].match(/href="([^"]+)"[^>]*>\s*([^<]+)</); if (!a) continue;
      const lift = ({ SN: 'snatch', CJ: 'cj', TOTAL: 'total' } as Record<string, string>)[a[2].trim().toUpperCase()]; if (!lift) continue;
      cells++;
      const kg = parseFloat(txt(tds[1]).replace(/kg/i, '')); if (!(kg > 0)) continue; // 0kg = no record yet
      let name = txt(tds[2]); if (!name || /^\d{4}-\d{2}-\d{2}$/.test(name) || /^\d{1,2}\/\d{1,2}\/\d{4}$/.test(name)) name = 'Name not listed';
      const set_on = auDate(txt(tds[3])); if (!set_on) continue;
      const comp = txt(tds[4] || '').replace(/\s+,/g, ',') || null;
      rows.push({ ...c, lift, weight_kg: kg, lifter_name: name, set_on, competition: comp, source_url: ent(a[1]) });
    }
  }
  return { rows, cells };
}

// ---- Wikipedia wikitext ----
function splitTop(s: string, sep: string): string[] { // split on sep outside [[ ]] and {{ }}
  const out: string[] = []; let d = 0, cur = '';
  for (let i = 0; i < s.length; i++) {
    const two = s.slice(i, i + 2);
    if (two === '[[' || two === '{{') { d++; cur += two; i++; continue; }
    if ((two === ']]' || two === '}}') && d > 0) { d--; cur += two; i++; continue; }
    if (d === 0 && s.startsWith(sep, i)) { out.push(cur); cur = ''; i += sep.length - 1; continue; }
    cur += s[i];
  }
  out.push(cur); return out;
}
function cellOf(raw: string): { v: string; rs: number } {
  const p = splitTop(raw, '|');
  if (p.length > 1 && /^\s*(rowspan|colspan|align|style|bgcolor|width|class|data-sort-value)\b/i.test(p[0])) {
    const rs = p[0].match(/rowspan\s*=\s*"?(\d+)/i); return { v: p.slice(1).join('|'), rs: rs ? +rs[1] : 1 };
  }
  return { v: raw, rs: 1 };
}
function clean(s: string): string {
  s = s.replace(/<ref[^>]*\/>/g, '').replace(/<ref[\s\S]*?<\/ref>/g, '');
  for (let k = 0; k < 5; k++) s = s.replace(/\{\{([^{}]*)\}\}/g, (_, inner: string) => {
    const a = inner.split('|'), n = a[0].trim().toLowerCase();
    if (/^flag/.test(n) || n === 'nowrap' || n === 'sortname') return (n === 'sortname' ? a.slice(1, 3).join(' ') : a[1] || '');
    return '';
  });
  s = s.replace(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/g, '$1').replace(/'{2,}/g, '').replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]+>/g, '');
  return ent(s).replace(/\s+/g, ' ').trim();
}
const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
function wikiDate(s: string): string | null {
  const m = s.match(/(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})/); if (!m) return null;
  const mo = MONTHS.indexOf(m[2].toLowerCase()); return mo < 0 ? null : `${m[3]}-${String(mo + 1).padStart(2, '0')}-${String(+m[1]).padStart(2, '0')}`;
}
function wikiTable(text: string, sex: string): { rows: Row[]; cells: number } {
  const rows: Row[] = []; let cells = 0, cat: string | null = null, status = '', carry: ({ v: string; n: number } | null)[] = [];
  let cur: string[] | null = null;
  const flush = () => {
    if (!cur || !cat) { cur = null; return; }
    const out: string[] = []; let k = 0;
    for (let col = 0; col < 8; col++) {
      if (carry[col] && carry[col]!.n > 0) { out.push(carry[col]!.v); carry[col]!.n--; continue; }
      if (k >= cur.length) { out.push(''); continue; }
      const c = cellOf(cur[k++]); out.push(c.v); carry[col] = c.rs > 1 ? { v: c.v, n: c.rs - 1 } : null;
    }
    cur = null;
    const ev = clean(out[0]).toLowerCase(), lift = ev.startsWith('snatch') ? 'snatch' : ev.startsWith('clean') ? 'cj' : ev.startsWith('total') ? 'total' : null;
    if (!lift) return;
    cells++;
    if (status === 'pink') return; // not ratified or rescinded
    const kg = parseFloat(clean(out[1]).replace(',', '.')); if (!(kg > 0)) return;
    const name = clean(out[2]) || 'World Standard', std = /world standard/i.test(name);
    const set_on = wikiDate(clean(out[4])) || '2026-08-01';
    const meet = clean(out[5]), place = clean(out[6]);
    rows.push({ sex, category: cat, lift, weight_kg: kg, lifter_name: std ? 'World Standard' : name, set_on, nation: clean(out[3]) || null,
      competition: [meet, place].filter(Boolean).join(', ') || null, source_url: 'https://iwf.sport/results/world-records/',
      note: status === 'pending' ? 'Awaiting ratification' : std ? 'Minimum set by the IWF for the new classes' : null });
  };
  for (const line of text.split('\n')) {
    if (line.startsWith('|-')) { flush(); cur = []; status = /pink/i.test(line) ? 'pink' : /CEF6F5/i.test(line) ? 'pending' : ''; continue; }
    if (line.startsWith('|}')) { flush(); continue; }
    if (line.startsWith('!')) {
      const c = cellOf(line.slice(1)); const m = clean(c.v).match(/^(\+?)\s*(\d+)\s*(\+?)\s*kg/i);
      if (/colspan/i.test(line) && m) { flush(); const k = ((m[1] || m[3]) ? '+' : '') + m[2]; cat = CATS[sex].includes(k) ? k : null; carry = []; cur = null; }
      continue;
    }
    if (line.startsWith('|') && cur) { for (const part of splitTop(line.slice(1), '||')) cur.push(part); continue; }
  }
  flush();
  return { rows, cells };
}
async function world(): Promise<{ rows: Row[]; cells: number }> {
  const r = await fetch('https://en.wikipedia.org/w/api.php?action=parse&page=List_of_world_records_in_Olympic_weightlifting&prop=wikitext&format=json&formatversion=2', { headers: { 'User-Agent': WIKI_UA } });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const wt: string = (await r.json())?.parse?.wikitext || '';
  const cur = wt.split(/==\s*Historical records\s*==/)[0];
  const men = cur.split(/===\s*Men\s*===/)[1]?.split(/===\s*Women\s*===/)[0] || '';
  const women = cur.split(/===\s*Women\s*===/)[1] || '';
  const a = wikiTable(men, 'male'), b = wikiTable(women, 'female');
  return { rows: [...a.rows, ...b.rows], cells: a.cells + b.cells };
}

const SOURCES: Record<string, { source: string; url: string; get: () => Promise<{ rows: Row[]; cells: number }> }> = {
  wa: { source: 'wwa', url: 'https://www.wwa.org.au/Statistics/Records', get: () => australian('https://www.wwa.org.au/Statistics/Records') },
  aus: { source: 'awf', url: 'https://www.awf.com.au/competition/statistics/records', get: () => australian('https://www.awf.com.au/competition/statistics/records') },
  world: { source: 'wiki', url: 'https://iwf.sport/results/world-records/', get: world },
};

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  // the key lives in private.app_config ('records_sync_secret'); pg_cron and rpc records_sync_now send it
  const key = req.headers.get('x-sync-secret') || '';
  const { data: okKey } = key ? await sb.rpc('records_sync_check', { p_secret: key }) : { data: false };
  if (okKey !== true) return new Response('Unauthorised', { status: 401 });
  let body: { levels?: string[]; dry?: boolean } = {};
  try { body = await req.json(); } catch { /* no body */ }
  const levels = (body.levels?.length ? body.levels : Object.keys(SOURCES)).filter(l => SOURCES[l]);
  const { data: prev } = await sb.from('app_settings').select('value').eq('key', 'records_sync').maybeSingle();
  const status: Record<string, unknown> = { ...(prev?.value || {}) };
  const report: Record<string, unknown> = {};
  for (const lvl of levels) {
    const s = SOURCES[lvl], at = new Date().toISOString();
    try {
      const { rows, cells } = await s.get();
      // 16 classes x 3 lifts = 48 cells on the source; anything well short means the page changed, so leave the board alone
      if (cells < 40) throw new Error(`only found ${cells} of 48 record cells, the page may have changed`);
      if (body.dry) { report[lvl] = { cells, rows }; continue; }
      const { data: n, error } = await sb.rpc('records_sync_apply', { p_level: lvl, p_source: s.source, p_rows: rows });
      if (error) throw new Error(error.message);
      status[lvl] = { ok: true, at, count: n, cells, url: s.url };
      report[lvl] = { ok: true, count: n, cells };
    } catch (e) {
      const msg = String((e as Error)?.message || e).slice(0, 200);
      status[lvl] = { ...((status[lvl] as object) || {}), ok: false, error: msg, tried: at, url: s.url };
      report[lvl] = { ok: false, error: msg };
    }
  }
  if (!body.dry) await sb.from('app_settings').upsert({ key: 'records_sync', value: status, updated_at: new Date().toISOString() });
  return new Response(JSON.stringify(report), { headers: { 'content-type': 'application/json' } });
});
