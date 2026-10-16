import sys, os, collections
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import iff
cnt = collections.Counter()
def walk(cs, path):
    for c in cs:
        p = path + '/' + c.name
        cnt[p] += 1
        walk(c.children, p)
for d in sys.argv[1:]:
    for fn in sorted(os.listdir(d)):
        try: walk(iff.load(os.path.join(d, fn)), '')
        except Exception as e: print('ERR', fn, e)
for k, v in sorted(cnt.items()): print(v, k)
