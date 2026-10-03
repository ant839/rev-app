"""Turn the FNDN program spreadsheet (ENTIRE PROGRAM tab) into a program-builder plan doc.

Usage: python3 fndn_import.py <file.xlsx> <from YYYY-MM-DD> <out.json> [exercise ids json] [existing plan json]
Strength C finishers, Engine and Saturday workouts become conditioning blocks (scored: rounds / time / cals / done / text).
Reads every phase, keeps the weeks from the given Monday on, and writes the doc that
private.builder_save_plan(doc) takes (tracks Strength / Engine / Oly, FNDN group roster, draft).
"""
import json, re, sys, datetime as dt
import openpyxl

YEAR = 2026
PLAN = {}   # existing plan to save into: {'id': plan uuid, 'programs': {'<block>|<track>': program uuid}}
FNDN_GROUP = '245f3a87-6085-4eb4-9607-dd68628fd48b'
DAYCOLS = {1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6}      # sheet column -> day number (Mon=1)
OLYCOLS = {7: 2, 8: 4}                                # Oly Tue, Oly Thu
MON = {m: i + 1 for i, m in enumerate('Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split())}

# Sheet name -> exercise name in the app library (anything not here is used as written)
EX_MAP = {'Clean and Jerk': 'Clean & Jerk'}
PCT_OF = {'Hang Snatch (Knee)': 'Snatch', 'Snatch': None, 'Hang Clean (Knee)': 'Clean',
          'Jerk from Rack': 'Clean & Jerk', 'Clean & Jerk': None}


def cell(ws, r, c):
    v = ws.cell(r, c).value
    return '' if v is None else str(v).strip()


def parse_date(s):
    m = re.match(r'(\d{1,2}) (\w{3})', s.strip())
    return dt.date(YEAR, MON[m.group(2)], int(m.group(1))) if m else None


def lines(s):
    return [l.rstrip() for l in s.split('\n')]


def strength_a(detail):
    """'Build to a 3RM — 8 Timed Sets / Every 2 min: Bar x8, 50% x5 ... / Every 3 min: 75% x3, ... Build from here x3'"""
    sets, warm = [], []
    m2 = re.search(r'Every 2 min:\s*(.+)', detail)
    m3 = re.search(r'Every 3 min:\s*(.+)', detail)
    if not (m2 and m3):
        return None
    for part in m2.group(1).split(','):
        p = part.strip()
        mm = re.match(r'(Bar|\d+(?:\.\d+)?%)\s*x(\d+)', p)
        if mm:
            pct = None if mm.group(1) == 'Bar' else float(mm.group(1).rstrip('%'))
            warm.append({'sets': 1, 'reps': mm.group(2), 'percent': pct, 'load_text': 'Bar' if pct is None else None, 'warmup': True})
    parts = [p.strip() for p in m3.group(1).split(',')]
    for i, p in enumerate(parts):
        mm = re.match(r'(\d+(?:\.\d+)?)%\s*x(\d+)', p)
        if mm:
            sets.append({'sets': 1, 'reps': mm.group(2), 'percent': float(mm.group(1))})
        else:
            mm = re.match(r'(.+?)\s*x(\d+)\s*(\((.+)\))?', p)
            sets.append({'sets': 1, 'reps': mm.group(2), 'load_text': mm.group(1).strip(), 'notes': mm.group(4)})
    sets[0]['notes'] = 'Every 3 min from here'
    return warm + sets, 'Build to a 3RM, 8 timed sets. Build-up sets every 2 min, then every 3 min. The last set is your 3RM attempt.'


def strength_b(detail):
    m = re.search(r'Working:\s*(\d+)\s*x\s*(\d+)\s*@\s*RPE\s*(\d+(?:\.\d+)?)\s*(?:—\s*every\s*([\d:]+))?', detail)
    if not m:
        return None
    note = ('Every ' + m.group(4) + ', after 3 building sets every 2 min') if m.group(4) else '3 building sets first'
    sub = re.search(r'If reps not achievable:\s*(.+)', detail)
    if sub:
        note += '. If reps not achievable: ' + sub.group(1).strip()
    return [{'sets': int(m.group(1)), 'reps': m.group(2), 'rpe': float(m.group(3)), 'notes': note}], None


def oly(detail):
    m = re.match(r'Build to an? (heavy|moderate|light and snappy) (\d+(?:\+\d+)?)', detail)
    if not m:
        return None
    r = m.group(2)
    word = r + (' rep' if r == '1' else ' reps') if r.isdigit() else r
    return [{'sets': 1, 'reps': r, 'load_text': 'Build to a %s %s for the day.' % (m.group(1), word)}], None


def score_for(title, body):
    """How athletes log a conditioning piece: rounds / time / cals / done / text."""
    t, b = title.lower(), body.lower()
    if 'death by' in t: return 'rounds'
    if re.search(r'\d+\s*x\s*amrap', t) or 'part' in t or 'score:' in b: return 'text'
    if 'amrap' in t: return 'rounds'
    if 'for time' in t or re.match(r'^\d+(-\d+)+', t): return 'time'
    if 'emom' in t: return 'done'
    if ('cal' in b or 'bike' in b) and 'max' in b and 'odd' not in b: return 'cals'
    return 'text'


def cond_item(label, title, body, ex_ids):
    """A conditioning block: the Conditioning exercise, the workout in notes, guide.cond = {title, score}."""
    return {'label': label, 'exercise_id': ex_ids.get('conditioning'), 'new_exercise': '' if ex_ids.get('conditioning') else 'Conditioning',
            'percent_of': None, 'notes': body.strip(), 'hold': True,
            'guide': {'off': True, 'cond': {'title': title.strip(), 'score': score_for(title, body)}},
            'sets': [{'sets': 1, 'reps': '1', 'percent': None, 'percent_max': None, 'rpe': None, 'load_text': title.strip(), 'notes': None, 'warmup': False}]}


def item(label, name, rx, ex_ids):
    name = EX_MAP.get(name, name)
    sets, notes = rx
    it = {'label': label, 'exercise_id': ex_ids.get(name.lower()), 'new_exercise': '' if ex_ids.get(name.lower()) else name,
          'percent_of': ex_ids.get((PCT_OF.get(name) or '').lower()) if PCT_OF.get(name) else None,
          'notes': notes or '', 'hold': True, 'guide': None, 'sets': []}
    for s in sets:
        it['sets'].append({'sets': s.get('sets', 1), 'reps': str(s.get('reps', '1')), 'percent': s.get('percent'), 'percent_max': None,
                           'rpe': s.get('rpe'), 'load_text': s.get('load_text'), 'notes': s.get('notes'), 'warmup': bool(s.get('warmup'))})
    return it


def build(path, start_from, ex_ids):
    ws = openpyxl.load_workbook(path, data_only=True)['ENTIRE PROGRAM']
    phases, cur = [], None
    r, R = 1, ws.max_row
    while r <= R:
        a = cell(ws, r, 1)
        if a.startswith('PHASE') and '—' in a and 'WARMUPS' not in a:
            m = re.match(r'PHASE (\w+)\s*—\s*(.+?)\s*\((\d+ \w+) – (\d+ \w+) (\d{4})\)', a)
            t = re.sub(r'\s+BLOCK$', '', m.group(2).strip()).lower()
            t = re.sub(r'(\d)rm', r'\1RM', t)
            cur = {'title': t[:1].upper() + t[1:], 'num': str({'ONE': 1, 'TWO': 2, 'THREE': 3, 'FOUR': 4, 'FIVE': 5, 'SIX': 6}.get(m.group(1), m.group(1))), 'start': parse_date(m.group(3)), 'weeks': [], 'warm': {}}
            phases.append(cur)
        elif a == 'WARMUP' and cur:  # same warm-up every week of the phase
            for c, d in DAYCOLS.items():
                v = cell(ws, r, c + 1)
                if v and v != '—':
                    cur['warm'][d] = v
        elif a.startswith('WEEK') and cur:
            wk = int(re.match(r'WEEK (\d+)', a).group(1))
            daterow = r + 2
            week = {'n': wk, 'days': {}}
            for c in range(2, 8):
                head = cell(ws, daterow, c)
                week['days'][c - 1] = {'date': parse_date(head), 'type': head.split('|')[1].strip() if '|' in head else '',
                                       'code': head.split('|')[2].strip() if head.count('|') >= 2 else '', 'parts': []}
            week['oly'] = {2: [], 4: []}
            rr = daterow + 1
            while rr <= R and cell(ws, rr, 1) in ('A', 'B', 'C'):
                lab = cell(ws, rr, 1)
                for c in range(2, 8):
                    t, dtl = cell(ws, rr, c), cell(ws, rr + 1, c)
                    if t:
                        week['days'][c - 1]['parts'].append((lab, t, dtl))
                for c, d in OLYCOLS.items():
                    t, dtl = cell(ws, rr, c + 1), cell(ws, rr + 1, c + 1)
                    if t:
                        week['oly'][d].append((lab, re.sub(r'^[A-C]\.\s*', '', t), dtl))
                rr += 2
            cur['weeks'].append(week)
            r = rr - 1
        r += 1

    # Keep the phase that contains start_from (and any after it)
    keep = [p for p in phases if p['start'] + dt.timedelta(weeks=len(p['weeks'])) > start_from]
    plan_start = keep[0]['start']
    blocks, programs, problems = [], [], []
    for bi, ph in enumerate(keep):
        blocks.append({'name': 'Phase %s · %s' % (ph['num'], ph['title']), 'weeks': len(ph['weeks']),
                       'focus': '', 'tracks': [
                           {'key': 'strength', 'name': 'Strength', 'kind': 'strength', 'mode': 'progressive', 'auto': False, 'inc': 0, 'warmDefault': False, 'choice': True, 'select': False, 'perVersion': False, 'is_template': False},
                           {'key': 'engine', 'name': 'Engine', 'kind': 'other', 'mode': 'progressive', 'auto': False, 'inc': 0, 'warmDefault': False, 'choice': True, 'select': False, 'perVersion': False, 'is_template': False},
                           {'key': 'oly', 'name': 'Oly', 'kind': 'technical', 'mode': 'progressive', 'auto': False, 'inc': 0, 'warmDefault': False, 'choice': True, 'select': False, 'perVersion': False, 'is_template': False}]})
        tracks = {'Strength': [], 'Engine': [], 'Oly': []}
        for w in ph['weeks']:
            for d, day in w['days'].items():
                if not day['date'] or day['date'] < start_from:
                    continue
                warm = ph['warm'].get(d)
                if 'STRENGTH' in day['type']:
                    items = []
                    for lab, t, dtl in day['parts']:
                        if lab == 'C':
                            items.append(cond_item('C', t, dtl, ex_ids)); continue
                        rx = strength_a(dtl) if lab == 'A' else strength_b(dtl)
                        if not rx:
                            problems.append('%s %s %s: could not read "%s"' % (day['date'], lab, t, dtl[:60])); continue
                        items.append(item(lab, t, rx, ex_ids))
                    notes = []
                    if warm: notes.append('WARM-UP\n' + warm)
                    title = ' + '.join(p[1] for p in day['parts'] if p[0] != 'C')
                    tracks['Strength'].append({'week': w['n'], 'day': d, 'title': title, 'notes': '\n\n'.join(notes), 'code': day['code'], 'items': items})
                else:
                    t, dtl = day['parts'][0][1], day['parts'][0][2]
                    notes = 'WARM-UP\n' + warm if warm else ''
                    title = 'Saturday' if d == 6 else 'Engine'
                    tracks['Engine'].append({'week': w['n'], 'day': d, 'title': title, 'notes': notes, 'code': day['code'], 'items': [cond_item('', t, dtl, ex_ids)]})
            for d, parts in w['oly'].items():
                date = plan_start + dt.timedelta(days=(sum(len(p['weeks']) for p in keep[:bi]) + w['n'] - 1) * 7 + d - 1)
                if date < start_from or not parts:
                    continue
                items = []
                for lab, t, dtl in parts:
                    rx = oly(dtl)
                    if not rx:
                        problems.append('%s Oly %s %s: could not read "%s"' % (date, lab, t, dtl[:60])); continue
                    items.append(item(lab, t, rx, ex_ids))
                tracks['Oly'].append({'week': w['n'], 'day': d, 'title': 'Oly · ' + ' + '.join(EX_MAP.get(p[1], p[1]) for p in parts),
                                      'notes': '', 'code': 'FNDN P%dW%dD%dO' % (bi + 1, w['n'], d), 'items': items})
        for tn, ss in tracks.items():
            kind = {'Strength': 'strength', 'Engine': 'other', 'Oly': 'technical'}[tn]
            programs.append({'id': PLAN.get('programs', {}).get('%d|%s' % (bi, tn)), 'block_index': bi, 'name': 'FNDN · %s · %s' % (blocks[-1]['name'], tn), 'kind': kind, 'track': tn,
                             'phase': blocks[-1]['name'], 'days_version': None, 'is_select': False, 'is_option': True, 'is_template': False, 'sessions': ss})
    doc = {'id': PLAN.get('id'), 'name': 'FNDN', 'plan_type': 'FNDN', 'athlete_id': None, 'start_date': plan_start.isoformat(),
           'total_weeks': sum(b['weeks'] for b in blocks), 'training_days': [1, 2, 3, 4, 5, 6], 'versions': [],
           'roster': {'groups': [FNDN_GROUP], 'members': []}, 'goals': None, 'code_prefix': 'FNDN', 'blocks': blocks, 'programs': programs}
    return doc, problems


if __name__ == '__main__':
    path, frm, out = sys.argv[1], dt.date.fromisoformat(sys.argv[2]), sys.argv[3]
    ex_ids = json.load(open(sys.argv[4])) if len(sys.argv) > 4 else {}
    if len(sys.argv) > 5: PLAN.update(json.load(open(sys.argv[5])))
    doc, problems = build(path, frm, ex_ids)
    json.dump(doc, open(out, 'w'), ensure_ascii=False)
    for p in doc['programs']:
        print(p['track'], len(p['sessions']), 'sessions', sum(len(s['items']) for s in p['sessions']), 'lifts')
    print('PROBLEMS:', problems or 'none')
