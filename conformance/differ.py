#!/usr/bin/env python3
"""Differ: BEAM port vs the Python referee, exactly as conformance/harness.py
compares the TypeScript port. The referee is used as a black-box oracle
(expected outputs computed at run time, never hardcoded); the Elixir results
file is produced by conformance/runner.exs.

Usage:
  python3 conformance/differ.py <spec-repo> <cases.json> <results.ex.json>

Exit code 0 iff derive outputs, verify answers, witness freshness and
closure-root digests all agree under Python ==, plus the pinned three-way
checkpoint expectations (CKPT_V2_EXPECTED) hold for the BEAM answers.
"""
import importlib.util
import json
import sys
from pathlib import Path

SPEC = Path(sys.argv[1])
CASES = json.loads(Path(sys.argv[2]).read_text())
GOT = {r["name"]: r for r in json.loads(Path(sys.argv[3]).read_text())}


def load_referee():
    p = SPEC / "referee" / "fold.py"
    spec = importlib.util.spec_from_file_location("fold_referee", p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


ref = load_referee()
derive, verify = ref.derive, ref.verify_checkpoint

CKPT_V2_EXPECTED = {
    "ckpt-v2-verified": "VERIFIED",
    "ckpt-v2-state-only-grown": "STATE-ONLY",
    "ckpt-v2-mismatch-state": "MISMATCH",
    "ckpt-v2-tampered-root": "STATE-ONLY",
    "ckpt-v2-reason-verified": "VERIFIED",
    "ckpt-v2-reason-tamper": "STATE-ONLY",
}

tot = {"derive": 0, "verify": 0, "fresh": 0, "roots": 0}
bad = {"derive": [], "verify": [], "fresh": [], "roots": []}
probe_tot = fresh_tot = roots_tot = 0

for case in CASES:
    name = case["name"]
    recs = case["records"]
    exp_derive = derive([dict(r) for r in recs])
    exp_verify = [
        verify([dict(r) for r in recs],
               {k: p[k] for k in ("at", "state", "closureRoot") if k in p})
        for p in case["probes"]
    ]
    exp_fresh = ref.witness_freshness([dict(r) for r in recs])
    exp_roots = {rid: ref.checkpoint_root([dict(r) for r in recs], rid)
                 for rid in exp_derive["order"]}
    probe_tot += len(case["probes"])
    fresh_tot += len(exp_fresh)
    roots_tot += len(exp_roots)

    got = GOT.get(name)
    if got is None:
        bad["derive"].append((name, "missing from BEAM results"))
        continue
    if got["derive"] == exp_derive:
        tot["derive"] += 1
    else:
        fields = [f for f in ("state", "order", "conflicts", "orphans")
                  if got["derive"][f] != exp_derive[f]]
        bad["derive"].append((name, "fields differ: " + ",".join(fields)))
        for f in fields[:1]:
            print(f"  [{name}] field {f}:")
            print(f"    py: {json.dumps(exp_derive[f], sort_keys=True)[:500]}")
            print(f"    ex: {json.dumps(got['derive'][f], sort_keys=True)[:500]}")
    if got["verify"] == exp_verify:
        tot["verify"] += len(exp_verify)
    else:
        bad["verify"].append((name, f"py={exp_verify} ex={got['verify']}"))
    if got.get("freshness") == exp_fresh:
        tot["fresh"] += len(exp_fresh)
    else:
        bad["fresh"].append((name, f"py={exp_fresh} ex={got.get('freshness')}"))
    if got.get("roots") == exp_roots:
        tot["roots"] += len(exp_roots)
    else:
        diff = [k for k in exp_roots if (got.get("roots") or {}).get(k) != exp_roots[k]]
        bad["roots"].append((name, f"root digests differ for {diff[:4]}"))

pin_fail = []
for nm, want in CKPT_V2_EXPECTED.items():
    case = next(c for c in CASES if c["name"] == nm)
    p0 = case["probes"][0]
    got_v = GOT[nm]["verify"][0]
    if got_v != want:
        pin_fail.append((nm, want, got_v))

print(f"derive:    {tot['derive']}/{len(CASES)} cases identical")
print(f"verify:    {tot['verify']}/{probe_tot} probes identical")
print(f"freshness: {tot['fresh']}/{fresh_tot} checks identical")
print(f"roots:     {tot['roots']}/{roots_tot} closure-root digests identical")
print(f"three-way pins: {len(CKPT_V2_EXPECTED) - len(pin_fail)}/{len(CKPT_V2_EXPECTED)}")
for kind in bad:
    for name, why in bad[kind][:15]:
        print(f"  DIVERGENCE[{kind}] {name}: {why}")
for nm, want, got_v in pin_fail:
    print(f"  PIN FAILURE {nm}: expected {want}, BEAM gave {got_v}")

ok = (tot["derive"] == len(CASES) and tot["verify"] == probe_tot
      and tot["fresh"] == fresh_tot and tot["roots"] == roots_tot
      and not pin_fail)
print("BEAM CONFORMANCE:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
