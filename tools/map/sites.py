"""The sites file for Living Front's district battle: every building of Downtown North that men can hold, read back
from what place_all.py wrote (Stalingrad.pzw's lots and the .tbx files in buildings.zip), as a Lua table.

  python3 buildings/sites.py [pzw] [buildings.zip] [out.lua]

Per building: its box (world tiles), storeys, the sector it stands in, whether it is the sector's objective, and its
SECTIONS - the parts of it one side can hold while the other holds the rest: its stair sections (the floor split
between its stairwells, across the long axis) or, with no stairs, wings of about WING tiles; a small building is one
section. Each section has a box and an anchor (a covered ground-floor square near its middle).
Run after place_all.py, whenever the map is regenerated."""
import collections, json, re, sys, zipfile
import numpy as np

LFD = '/home/claude/boid-at-the-gates/LivingFront/42/media/lua/client/LivingFront/World/LF_District.lua'
OUT = '/home/claude/boid-at-the-gates/LivingFront/42/media/lua/client/LivingFront/World/LF_Sites_DowntownNorth.lua'
PZW = '/mnt/user-data/outputs/stal_buildings/Stalingrad.pzw'
ZIP = '/mnt/user-data/outputs/stal_buildings/buildings.zip'
MIN_COVER = 14          # covered ground squares for a building to count (smaller: a shed, a ruin's stump)
SMALL = 140             # a building with fewer covered ground squares is one section
WING = 16               # with no stairwells to cut at: wings this long
MIN_PART = 40           # no section smaller than this (squares): merged into its neighbour


def args():
    a = sys.argv[1:]
    return (a[0] if len(a) > 0 else PZW), (a[1] if len(a) > 1 else ZIP), (a[2] if len(a) > 2 else OUT)


def district():
    src = open(LFD).read()
    keys = re.findall(r'key = "(\w+)"[^\n]*sector = ', src)
    secs = [[tuple(map(int, p)) for p in re.findall(r'\{ (\d+), (\d+) \}', s)]
            for s in re.findall(r'sector = \{ ((?:\{ \d+, \d+ \},? ?)+)\}', src)]
    at = {k: (int(a), int(b)) for k, a, b in re.findall(r'key = "(\w+)", title = "[^"]*", weight = \d+, at = \{ (\d+), (\d+) \}', src)}
    return keys, secs, at


def inside(poly, x, y):
    c = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]; x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1): c = not c
    return c


def tbx_floors(xml):
    """per floor: the room grid (h x w, 0 = none) and the room names (1-based)"""
    names = [m for m in re.findall(r'<room Name="([^"]*)"', xml)]
    w = int(re.search(r'<building [^>]*width="(\d+)"', xml).group(1))
    h = int(re.search(r'<building [^>]*height="(\d+)"', xml).group(1))
    floors = []
    for body in re.findall(r'<rooms>\s*(.*?)\s*</rooms>', xml, re.S):
        rows = [r for r in body.strip().split('\n') if r.strip()]
        g = np.zeros((h, w), np.int32)
        for y, r in enumerate(rows[:h]):
            v = [int(t) for t in r.strip().rstrip(',').split(',') if t != '']
            g[y, :min(w, len(v))] = v[:w]
        floors.append(g)
    return names, floors, w, h


def lots(pzw):
    out = []
    for cell in re.finditer(r'<cell x="(\d+)" y="(\d+)"[^>]*>(.*?)</cell>', pzw, re.S):
        cx, cy = int(cell.group(1)), int(cell.group(2))
        for m in re.finditer(r'<lot x="(\d+)" y="(\d+)" level="(\d+)" width="(\d+)" height="(\d+)" map="buildings/([^"]+)"', cell.group(3)):
            x, y, lv, w, h, f = m.groups()
            out.append((cx * 256 + int(x), cy * 256 + int(y), int(lv), f))
    return out


def components(mask):
    import cv2
    n, lab = cv2.connectedComponents(mask.astype(np.uint8), connectivity=4)
    return [(lab == i) for i in range(1, n)]


def sections(cov, stairs):
    """cut a building's covered ground floor (bool h x w) into parts: list of bool masks"""
    parts = []
    for comp in components(cov):
        n = int(comp.sum())
        if n < MIN_COVER: continue
        ys, xs = np.nonzero(comp)
        long_x = (xs.max() - xs.min()) >= (ys.max() - ys.min())
        along = xs if long_x else ys
        a0, a1 = int(along.min()), int(along.max())
        if n < SMALL:
            parts.append(comp); continue
        # the stairwells in this piece, by where they stand along the long axis
        st = sorted(set(int(v) for v in (np.nonzero(stairs & comp_dil(comp))[1 if long_x else 0])))
        groups = []
        for v in st:
            if groups and v - groups[-1][-1] <= 3: groups[-1].append(v)
            else: groups.append([v])
        mids = [sum(g) / len(g) for g in groups]
        if len(mids) >= 2:
            cuts = [int((mids[i] + mids[i + 1]) / 2) for i in range(len(mids) - 1)]
        else:
            k = max(1, round((a1 - a0 + 1) / WING))
            cuts = [int(a0 + (a1 - a0 + 1) * i / k) for i in range(1, k)]
        edges = [a0] + cuts + [a1 + 1]
        A = np.arange(comp.shape[1])[None, :] if long_x else np.arange(comp.shape[0])[:, None]
        sub = [comp & (A >= edges[i]) & (A < edges[i + 1]) for i in range(len(edges) - 1)]
        # small slivers join their neighbour
        merged = []
        for s in sub:
            if merged and (s.sum() < MIN_PART or merged[-1].sum() < MIN_PART): merged[-1] = merged[-1] | s
            else: merged.append(s)
        parts.extend(m for m in merged if m.sum() > 0)
    return parts


def comp_dil(comp):
    import cv2
    return cv2.dilate(comp.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)


def anchor(mask):
    ys, xs = np.nonzero(mask)
    cx, cy = xs.mean(), ys.mean()
    i = int(np.argmin((xs - cx) ** 2 + (ys - cy) ** 2))
    return int(xs[i]), int(ys[i])


def main():
    pzw_p, zip_p, out_p = args()
    keys, secs, at = district()
    z = zipfile.ZipFile(zip_p)
    have = set(z.namelist())
    sites = []
    for X, Y, lv, f in lots(open(pzw_p).read()):
        if lv != 0 or f not in have: continue
        xml = z.read(f).decode('utf-8', 'replace')
        names, floors, w, h = tbx_floors(xml)
        if not floors: continue
        def cov(g):
            m = np.zeros(g.shape, bool)
            for i, nm in enumerate(names, 1):
                if nm not in ('emptyoutside', 'stairwell'): m |= g == i
            return m
        g0 = floors[0]
        c0 = cov(g0)
        if c0.sum() < MIN_COVER: continue
        st0 = np.zeros(g0.shape, bool)
        for i, nm in enumerate(names, 1):
            if nm == 'stairwell': st0 |= g0 == i
        storeys = sum(1 for g in floors if cov(g).sum() >= MIN_COVER)
        parts = sections(c0, st0)
        if not parts: continue
        allm = np.zeros(c0.shape, bool)
        for p in parts: allm |= p
        ys, xs = np.nonzero(allm)
        x1, y1, x2, y2 = X + int(xs.min()), Y + int(ys.min()), X + int(xs.max()), Y + int(ys.max())
        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
        sec = None
        for k, poly in zip(keys, secs):
            if inside(poly, cx, cy): sec = k; break
        if sec is None: continue                        # outside the district
        obj = None
        for k, (ax, ay) in at.items():
            if 0 <= ay - Y < h and 0 <= ax - X < w and c0[ay - Y, ax - X]: obj = k
            elif obj is None and x1 <= ax <= x2 and y1 <= ay <= y2 and f.startswith('lm_'): obj = k   # (a courtyard, a crater)
        P = []
        for p in parts:
            ys, xs = np.nonzero(p)
            ax, ay = anchor(p)
            P.append((X + int(xs.min()), Y + int(ys.min()), X + int(xs.max()), Y + int(ys.max()), X + ax, Y + ay, int(p.sum())))
        kind = f.split('_')[1] if f.startswith('dt_') else f.split('.')[0]
        sites.append(dict(f=f, box=(x1, y1, x2, y2), s=storeys, sec=sec, obj=obj, kind=kind, n=int(allm.sum()), parts=P))
    sites.sort(key=lambda s: (s['sec'], s['box'][1], s['box'][0]))
    L = ['-- Living Front: the buildings of Downtown North, for the district battle (LF_Battle, LF_Control).',
         '-- GENERATED by the Stalingrad map pipeline (buildings/sites.py) from the placed buildings - do not edit by hand.',
         '-- Each: box = { x1, y1, x2, y2 } (world tiles, inclusive), s = storeys, sec = sector key, obj = the objective it',
         '-- is (if it is one), n = covered ground squares, parts = its sections { x1, y1, x2, y2, anchorX, anchorY, squares }.',
         '', 'LF = LF or {}', 'LF.Sites = LF.Sites or {}', 'LF.Sites.downtown_north = {']
    for i, s in enumerate(sites, 1):
        b = s['box']
        parts = ', '.join('{ %d, %d, %d, %d, %d, %d, %d }' % p for p in s['parts'])
        L.append('    { id = %d, box = { %d, %d, %d, %d }, s = %d, sec = "%s",%s kind = "%s", n = %d, parts = { %s } },'
                 % (i, b[0], b[1], b[2], b[3], s['s'], s['sec'], (' obj = "%s",' % s['obj']) if s['obj'] else '', s['kind'], s['n'], parts))
    L.append('}')
    open(out_p, 'w').write('\n'.join(L) + '\n')
    by = collections.Counter(s['sec'] for s in sites)
    multi = sum(1 for s in sites if len(s['parts']) > 1)
    print('sites', len(sites), 'multi-section', multi, 'objectives', sorted(s['obj'] for s in sites if s['obj']))
    print(dict(by))


if __name__ == '__main__':
    main()
