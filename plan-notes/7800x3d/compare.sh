#!/bin/bash
# Differential analysis over one or more sweep.sh result CSVs.
#
# Three independent checks, none of which needs a table of reference residues:
#
#   1. cross-radset  - within one configuration, every radix set at a given FFT
#                      length must produce the same Res64. This is the check that
#                      has never been run; it covers all ~600 radix sets, most of
#                      which the self-test never touches.
#   2. cross-config  - the same (length, radset) must agree across build modes,
#                      thread counts and compilers. nosimd is the oracle.
#                      Grouped WITHIN a (type, shift) pair: a different shift or a
#                      different test type legitimately gives a different residue.
#   3. health        - anything that aborted, hit roundoff, or produced no residue.
#
# usage: ./compare.sh results/*/results.csv
#        ./compare.sh --selftest      (verify the checks actually fire)

set -uo pipefail
[[ $# -gt 0 ]] || { echo "usage: compare.sh <results.csv>... | --selftest" >&2; exit 1; }
exec python3 - "$@" <<'PYEOF'
import csv, sys, collections, itertools, tempfile, os

def load(paths):
    rows=[]
    for p in paths:
        with open(p, newline='') as fh:
            for r in csv.DictReader(fh):
                rows.append(r)
    return rows

def analyse(rows, out=sys.stdout):
    ok  = [r for r in rows if r['status']=='ok']
    bad = [r for r in rows if r['status']!='ok']
    problems = 0

    out.write("="*62 + "\n 1. CROSS-RADIX-SET  (within one config, all radix sets\n"
              "                      of a length must agree)\n" + "="*62 + "\n")
    # Group by everything EXCEPT radset, so the radsets land in the same bucket.
    g = collections.defaultdict(dict)
    for r in ok:
        g[(r['tag'], r['type'], r['shift'], r['kblocks'], r['exponent'])][r['radset']] = r['res64']
    hits = 0
    for (tag, ty, sh, k, p), byrs in sorted(g.items(), key=lambda x: int(x[0][3])):
        if len(set(byrs.values())) > 1:
            hits += 1; problems += 1
            out.write(f"  MISMATCH  {tag}  {k}K  p={p}\n")
            for rs, res in sorted(byrs.items(), key=lambda x: int(x[0])):
                out.write(f"            rs{rs:<3} {res}\n")
    out.write("  clean - every radix set agrees within its configuration\n" if not hits
              else f"  {hits} length(s) with disagreeing radix sets\n")

    out.write("\n" + "="*62 + "\n 2. CROSS-CONFIG  (same cell across configurations;\n"
              "                   grouped within a type+shift)\n" + "="*62 + "\n")
    g2 = collections.defaultdict(dict)
    for r in ok:
        g2[(r['type'], r['shift'], r['kblocks'], r['radset'], r['exponent'])][r['tag']] = r['res64']
    hits = 0
    for (ty, sh, k, rs, p), bytag in sorted(g2.items(), key=lambda x: int(x[0][2])):
        if len(set(bytag.values())) > 1:
            hits += 1; problems += 1
            out.write(f"  MISMATCH  type={ty} shift={sh}  {k}K rs{rs}  p={p}\n")
            byres = collections.defaultdict(list)
            for tag, res in bytag.items(): byres[res].append(tag)
            for res, tags in sorted(byres.items(), key=lambda x: -len(x[1])):
                out.write(f"            {res}  {' '.join(sorted(tags))}\n")
    out.write("  clean - every configuration agrees\n" if not hits
              else f"  {hits} cell(s) disagree across configurations\n")

    out.write("\n" + "="*62 + "\n 3. HEALTH  (skips are expected for Fermat)\n" + "="*62 + "\n")
    tally = collections.Counter((r['tag'], r['status']) for r in bad)
    for (tag, st), n in sorted(tally.items()):
        out.write(f"  {tag:<34} {st:<14} {n}\n")
    hard = [r for r in bad if r['status'] in ('abort','fail','nores')]
    out.write(f"\n  --- aborts / failures / missing residues ({len(hard)}) ---\n")
    for r in sorted(hard, key=lambda r:(int(r['kblocks']), r['tag']))[:60]:
        out.write(f"  {r['tag']:<32} {r['kblocks']}K rs{r['radset']:<3} {r['status']}\n")
    problems += len(hard)
    roe = [r for r in bad if r['status']=='roe']
    out.write(f"\n  --- roundoff ({len(roe)}) ---\n")
    for r in sorted(roe, key=lambda r: int(r['kblocks']))[:40]:
        out.write(f"  {r['tag']:<32} {r['kblocks']}K rs{r['radset']:<3} maxerr={r['maxerr']}\n")
    return problems

HDR = "tag,type,mode_threads,shift,kblocks,radset,exponent,res64,maxerr,avgmaxerr,radices,rc,seconds,status"
def row(tag,ty,sh,k,rs,p,res,st='ok'):
    return f"{tag},{ty},m/1,{sh},{k},{rs},{p},{res},0.2,0.2,16-16,0,1.0,{st}"

if sys.argv[1] == '--selftest':
    # A check that cannot fail is worse than no check. Prove each one fires.
    import io
    def run(lines):
        fd, path = tempfile.mkstemp(suffix='.csv')
        os.write(fd, ("\n".join([HDR]+lines)+"\n").encode()); os.close(fd)
        buf = io.StringIO(); n = analyse(load([path]), buf); os.unlink(path)
        return n, buf.getvalue()

    fails = []
    # 1. two radsets of one length disagree -> must be caught
    n,txt = run([row('A','ll',0,1024,0,999,'AAAA'), row('A','ll',0,1024,1,999,'BBBB')])
    if 'MISMATCH' not in txt or n==0: fails.append("cross-radset did not fire")
    # 2. two configs disagree on the same cell -> must be caught
    n,txt = run([row('A','ll',0,1024,0,999,'AAAA'), row('B','ll',0,1024,0,999,'BBBB')])
    if '2. CROSS-CONFIG' not in txt or 'MISMATCH  type=ll' not in txt: fails.append("cross-config did not fire")
    # 3. different shift, different residue -> must NOT be flagged
    n,txt = run([row('A','ll',0,1024,0,999,'AAAA'), row('A','ll',12345,1024,0,999,'BBBB')])
    if 'MISMATCH' in txt: fails.append("false positive: different shifts compared")
    # 4. different test type, different residue -> must NOT be flagged
    n,txt = run([row('A','ll',0,1024,0,999,'AAAA'), row('A','prp',0,1024,0,999,'BBBB')])
    if 'MISMATCH' in txt: fails.append("false positive: different types compared")
    # 5. agreeing data -> clean
    n,txt = run([row('A','ll',0,1024,0,999,'AAAA'), row('A','ll',0,1024,1,999,'AAAA'),
                 row('B','ll',0,1024,0,999,'AAAA'), row('B','ll',0,1024,1,999,'AAAA')])
    if 'MISMATCH' in txt or n!=0: fails.append("false positive on agreeing data")
    for f in fails: print("  SELFTEST FAIL:", f)
    print("  selftest: all 5 cases pass" if not fails else f"  {len(fails)} selftest failure(s)")
    sys.exit(1 if fails else 0)

sys.exit(1 if analyse(load(sys.argv[1:])) else 0)
PYEOF
