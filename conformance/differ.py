#!/usr/bin/env python3
"""Differ: BEAM port vs the Python referee, exactly as conformance/harness.py
compares the TypeScript port. The referee is used as a black-box oracle
(expected outputs computed at run time, never hardcoded); the Elixir results
file is produced by conformance/runner.exs.

Usage:
  python3 conformance/differ.py <spec-repo> <cases.json> <results.ex.json>

Exit code 0 iff derive outputs, verify answers, witness freshness,
closure-root digests and retraction surfaces all agree under Python ==,
plus the pinned three-way checkpoint expectations (CKPT_V2_EXPECTED) and
the pinned retraction expectations (RET_EXPECTED / RET_CONTESTED, imported
from the harness — the pins are never forked into this file) hold for the
BEAM answers.
"""
import importlib.util
import json
import sys
from pathlib import Path

SPEC = Path(sys.argv[1])
CASES = json.loads(Path(sys.argv[2]).read_text())
GOT = {r["name"]: r for r in json.loads(Path(sys.argv[3]).read_text())}


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_referee():
    return load_module("fold_referee", SPEC / "referee" / "fold.py")


ref = load_referee()
derive, verify = ref.derive, ref.verify_checkpoint

# The retraction pins live in the harness; import them from there so this
# differ can never drift from the corpus's own pinned answers.
_harness = load_module("conformance_harness", SPEC / "conformance" / "harness.py")
RET_EXPECTED = _harness.RET_EXPECTED
RET_CONTESTED = _harness.RET_CONTESTED

CKPT_V2_EXPECTED = {
    "ckpt-v2-verified": "VERIFIED",
    "ckpt-v2-state-only-grown": "STATE-ONLY",
    "ckpt-v2-mismatch-state": "MISMATCH",
    "ckpt-v2-tampered-root": "STATE-ONLY",
    "ckpt-v2-reason-verified": "VERIFIED",
    "ckpt-v2-reason-tamper": "STATE-ONLY",
}

tot = {"derive": 0, "verify": 0, "fresh": 0, "roots": 0}
bad = {"derive": [], "verify": [], "fresh": [], "roots": [], "retraction": []}
probe_tot = fresh_tot = roots_tot = 0
status_tot = status_ok = contested_tot = contested_ok = 0

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
    exp_ret = ref.retraction_status([dict(r) for r in recs])
    probe_tot += len(case["probes"])
    fresh_tot += len(exp_fresh)
    roots_tot += len(exp_roots)
    status_tot += len(exp_ret["disputes"])
    contested_tot += len(exp_ret["contested"])

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
    got_ret = got.get("retraction")
    if got_ret == exp_ret:
        status_ok += len(exp_ret["disputes"])
        contested_ok += len(exp_ret["contested"])
    else:
        fields = [f for f in ("disputes", "retracted", "contested")
                  if (got_ret or {}).get(f) != exp_ret[f]]
        bad["retraction"].append((name, "fields differ: " + ",".join(fields)))
        for f in fields[:1]:
            print(f"  [{name}] retraction field {f}:")
            print(f"    py: {json.dumps(exp_ret[f], sort_keys=True)[:500]}")
            print(f"    ex: {json.dumps((got_ret or {}).get(f), sort_keys=True)[:500]}")

pin_fail = []
for nm, want in CKPT_V2_EXPECTED.items():
    case = next(c for c in CASES if c["name"] == nm)
    p0 = case["probes"][0]
    got_v = GOT[nm]["verify"][0]
    if got_v != want:
        pin_fail.append((nm, want, got_v))

# Retraction pins against the BEAM answers (not just the referee's): the
# differential alone proves the ports agree; these pin WHICH answer is
# correct — state is already pinned via the derive comparison above, so
# here the dispute statuses, the retracted set, and the contested
# markings are pinned on the retraction surface itself.
ret_pin_fail = []
for nm, (_state, want_statuses, want_retracted) in RET_EXPECTED.items():
    got_ret = (GOT.get(nm) or {}).get("retraction") or {}
    if got_ret.get("disputes") != want_statuses:
        ret_pin_fail.append((nm, "disputes", want_statuses, got_ret.get("disputes")))
    if got_ret.get("retracted") != want_retracted:
        ret_pin_fail.append((nm, "retracted", want_retracted, got_ret.get("retracted")))
for nm, want_contested in RET_CONTESTED.items():
    got_ret = (GOT.get(nm) or {}).get("retraction") or {}
    if got_ret.get("contested") != want_contested:
        ret_pin_fail.append((nm, "contested", want_contested, got_ret.get("contested")))

print(f"derive:    {tot['derive']}/{len(CASES)} cases identical")
print(f"verify:    {tot['verify']}/{probe_tot} probes identical")
print(f"freshness: {tot['fresh']}/{fresh_tot} checks identical")
print(f"roots:     {tot['roots']}/{roots_tot} closure-root digests identical")
print(f"retraction: {status_ok}/{status_tot} dispute statuses, "
      f"{contested_ok}/{contested_tot} contested markings identical")
print(f"three-way pins: {len(CKPT_V2_EXPECTED) - len(pin_fail)}/{len(CKPT_V2_EXPECTED)}")
_ret_pin_tot = 2 * len(RET_EXPECTED) + len(RET_CONTESTED)
print(f"retraction pins: {_ret_pin_tot - len(ret_pin_fail)}/{_ret_pin_tot}")
for kind in bad:
    for name, why in bad[kind][:15]:
        print(f"  DIVERGENCE[{kind}] {name}: {why}")
for nm, want, got_v in pin_fail:
    print(f"  PIN FAILURE {nm}: expected {want}, BEAM gave {got_v}")
for nm, field, want, got_v in ret_pin_fail:
    print(f"  RET PIN FAILURE {nm} [{field}]: expected {want}, BEAM gave {got_v}")

ok = (tot["derive"] == len(CASES) and tot["verify"] == probe_tot
      and tot["fresh"] == fresh_tot and tot["roots"] == roots_tot
      and status_ok == status_tot and contested_ok == contested_tot
      and not pin_fail and not ret_pin_fail)
print("BEAM CONFORMANCE:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
