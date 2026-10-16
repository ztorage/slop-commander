"""Find coplanar, area-overlapping triangle pairs within each LOD (z-fight candidates)."""
import numpy as np

def _clip(poly, a, b):
    out = []
    def inside(p): return (b[0]-a[0])*(p[1]-a[1]) - (b[1]-a[1])*(p[0]-a[0]) >= -1e-9
    def inter(p, q):
        d1 = (b[0]-a[0])*(p[1]-a[1]) - (b[1]-a[1])*(p[0]-a[0])
        d2 = (b[0]-a[0])*(q[1]-a[1]) - (b[1]-a[1])*(q[0]-a[0])
        t = d1 / (d1 - d2); return p + (q - p) * t
    for i in range(len(poly)):
        p, q = poly[i], poly[(i+1) % len(poly)]
        if inside(q):
            if not inside(p): out.append(inter(p, q))
            out.append(q)
        elif inside(p):
            out.append(inter(p, q))
    return out

def _area(poly):
    if len(poly) < 3: return 0.0
    return 0.5 * abs(sum(poly[i][0]*poly[(i+1)%len(poly)][1] - poly[(i+1)%len(poly)][0]*poly[i][1] for i in range(len(poly))))

def overlap_area(t1, t2, n):
    ax = np.argmax(np.abs(n)); keep = [i for i in range(3) if i != ax]
    A = [p[keep] for p in t1]; B = [p[keep] for p in t2]
    if (A[1][0]-A[0][0])*(A[2][1]-A[0][1]) - (A[1][1]-A[0][1])*(A[2][0]-A[0][0]) < 0: A = A[::-1]
    if (B[1][0]-B[0][0])*(B[2][1]-B[0][1]) - (B[1][1]-B[0][1])*(B[2][0]-B[0][0]) < 0: B = B[::-1]
    poly = A
    for i in range(3):
        poly = _clip(poly, B[i], B[(i+1) % 3])
        if not poly: return 0.0
    return _area(poly)

def find_overlaps(V, tris, ids, plane_eps=2.0, min_frac=0.02):
    """Return list of (tid_a, tid_b, same_facing) for coplanar triangles whose areas overlap."""
    info = {}
    for t in ids:
        p = [V[i] for i in tris[t].v]
        n = np.cross(p[1]-p[0], p[2]-p[0]); l = np.linalg.norm(n)
        if l < 1e-9: continue
        info[t] = (p, n / l, l / 2)
    res = []
    keys = list(info)
    for i, a in enumerate(keys):
        pa, na, aa = info[a]
        for b in keys[i+1:]:
            pb, nb, ab = info[b]
            d = np.dot(na, nb)
            if abs(abs(d) - 1) > 1e-3: continue
            if max(abs(np.dot(na, q - pa[0])) for q in pb) > plane_eps: continue
            ov = overlap_area(pa, pb, na)
            if ov > min_frac * min(aa, ab):
                res.append((a, b, d > 0))
    return res
