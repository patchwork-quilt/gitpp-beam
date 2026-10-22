# git.pp on the BEAM — the fold, reimplemented from the spec alone

**The git.pp fold — the function that turns a set of provenance-carrying
records into one deterministic state — implemented a third time, in
Elixir/OTP, by an author who never read the other implementations.**
It exists to answer one question: is the written specification actually
sufficient for an independent implementation to produce byte-identical
results? Against the full conformance corpus, it is.

For: engineers evaluating git.pp who want proof the semantics are
portable rather than implementation-defined, and Elixir/OTP developers
who want the fold on their own runtime. Not for: anyone who needs the
production read path — this is a conformance port (a spike), and it has
**no delta-derivation path** (see Limits).

## Run it

Toolchain (user-local, no sudo — precompiled Hex builds):

```sh
mkdir -p ~/toolchain/beam && cd ~/toolchain/beam
curl -LO https://builds.hex.pm/builds/otp/amd64/ubuntu-24.04/OTP-27.3.4.9.tar.gz
curl -LO https://builds.hex.pm/builds/elixir/v1.20.4-otp-27.zip
mkdir otp elixir && tar xzf OTP-27.3.4.9.tar.gz -C otp --strip-components=1
unzip -q v1.20.4-otp-27.zip -d elixir
(cd otp && ./Install -minimal "$PWD")
export PATH=$HOME/toolchain/beam/otp/bin:$HOME/toolchain/beam/elixir/bin:$PATH
export ELIXIR_ERL_OPTIONS="+fnu" LANG=C.UTF-8
```

Then the unit tests (fold pins + the burn/restart drill):

```sh
mix test
```

And the conformance run — the one that matters. It regenerates the
corpus with the upstream harness, runs this port over it, and diffs
every output against the Python referee:

```sh
scripts/conformance.sh /path/to/git.pp-ng-clone
```

What just happened: the last line is the verdict — `BEAM CONFORMANCE:
PASS` means this implementation, written from documents alone, agreed
with the referee on every case the corpus holds. The current totals
(2026-10-21, against the grown corpus):

```
derive:    898/898 cases identical
verify:    1056/1056 checkpoint probes identical (v1 bool + v2 three-way)
freshness: 3259/3259 witness-freshness checks identical
roots:     16574/16574 closure-root digests identical
three-way pins: 6/6 (VERIFIED / STATE-ONLY / MISMATCH semantics)
float fuzz: 10018 doubles, 0 leaf-encoding mismatches vs CPython
```

## The model

Five concepts, in the order they compose:

- A **record** is one unit of completed work: an id, its parent ids,
  a kind (`witness` / `task` / `override`), labelled key effects, and
  a reason.
- The **fold** derives state from a set of records: for each key, the
  highest-class candidate wins; losers are preserved, never dropped;
  records whose parents are missing are orphans, reported as such.
  Arrival order is never an input — the same set folds to the same
  state in any order.
- A **checkpoint** names a covered set of records (one chain head, or
  a frontier of several) plus a digest of the state they derive.
- The **closure root** is a single hash over the covered set,
  constructed so two implementations can compare coverage without
  exchanging the set.
- **Witness freshness** measures how far behind the frontier a
  witness record sits — staleness as a number, not a vibe.

The port's shape (`lib/gitpp/`):

- `Gitpp.Fold` — the fold as a pure function: records → state,
  conflicts (winner + preserved losers), application order, orphans;
  plus `verify_checkpoint/2` (v1, v2, and the frontier array form),
  `checkpoint_root/2`, `witness_freshness/1`.
- `Gitpp.Canon` — the byte-level dialect layer: float64
  canonicalisation at ingest (DESIGN.md §5), CPython `json.dumps`
  canonical encoding (sort_keys / ensure_ascii / separators), and the
  pinned leaf-number encoding from CHECKPOINT-V2.md. This module is
  where cross-port identity is earned.
- `Gitpp.Project` — one GenServer per project. Records arrive as
  messages and accumulate in arrival order; the fold ignores that
  order (the burn test below proves it). The process is a projection;
  the record list is the truth.
- `Gitpp.ProjectSupervisor` — one-for-one supervision: the restart
  half of the doctrine. Nothing is recovered from a dead process.

Failure behaviour, as specified upstream and inherited here: a
checkpoint whose claimed state can't be reproduced answers MISMATCH;
one whose coverage is sound but whose state is carried by the root
alone answers STATE-ONLY; a duplicate tail record identical to the
closure's copy is dropped, while a divergent copy forces the full
fold. Wrong input degrades verdicts; it does not corrupt state.

## Honest limits

- **No delta path.** This port always derives from the records it is
  handed; it does not implement the checkpoint+tail delta derivation
  the TypeScript hub uses to make reads cheap. If you need the read
  path, you need git.pp-ng.
- **It is a spike.** A conformance proof and a spec test, not a
  service: no storage, no API, no deployment story.
- **Doc-only cuts both ways.** Where the spec was ambiguous, the port
  surfaced it as a finding rather than guessing from source — eight
  findings against DESIGN.md, the sharpest (an undefined
  "candidates") fixed upstream in the spec itself.

## The deep layer

**Written from the documents alone — and that is the result.** The
author worked from `DESIGN.md`, `docs/CHECKPOINT-V2.md`,
`docs/FRONTIER-CHECKPOINTS.md`, and the witness-freshness formula in
`docs/ENGINEERING.md` of git.pp-ng. The TypeScript and Python sources
were never opened; the Python referee served only as the harness uses
it — a black-box oracle that computes expected outputs at run time.
Byte-identical agreement under that discipline is evidence the spec
carries the semantics, not the original author's habits.

**The BEAM simplifies around the fold, not the fold.** The OTP parts
of this port — a GenServer per project, a supervisor, restart
semantics — are roughly 150 lines and were never the difficulty.
The difficulty is dialect: `Gitpp.Canon` is 293 of the port's 833
lines, spent reproducing another language's byte-level choices
exactly (how CPython spells a float, how it escapes a string, which
digits a leaf uses for a number in [1e16, 1e21)). Any third
implementation, in any language, should budget for the same tax: the
algorithm is small; agreeing byte-for-byte is the work.

**Burn it, and nothing changes.** The burn test kills the per-project
GenServer with `:kill`; the supervisor restarts it empty; the record
log is re-fed **in reverse arrival order** — and the digest and
derive output come back byte-identical (`test/burn_test.exs`). State
that survives its process being shot, fed backwards, is state whose
semantics never depended on the process at all.

**The scar: frontier checkpoints.** When the corpus grew frontier
(array-form) checkpoints, this port silently had no implementation
for them — re-running conformance found **ten diverging verify
probes**, answers of MISMATCH and false where the referee said
VERIFIED, STATE-ONLY, and true. The fix (PR #9) computes the covered
set as the union of the frontier members' ancestor closures, digested
by the identical v2 construction; singleton behaviour is
byte-identical to before. The fix is mutation-proven: breaking the
union back to first-member-only re-breaks seven of the cases. The
lesson the port keeps: a green suite proves agreement with the
corpus you ran, and a port that isn't re-run against a growing corpus
drifts in silence.

**Floats are where ports go to disagree.** Separately from the main
corpus, the leaf-number encoding was fuzzed against CPython on
10,018 doubles: zero mismatches (`conformance/float_fuzz.py` +
`float_fuzz.exs`). Number spelling feels like a detail until two
implementations hash the same value into different leaves — the
upstream LEAF-BAND family exists because exactly that drift once
shipped in the hub.

## Verify it yourself

```sh
mix test
scripts/conformance.sh /path/to/git.pp-ng-clone   # expect: BEAM CONFORMANCE: PASS
python3 conformance/float_fuzz.py > /tmp/floats.tsv
mix run conformance/float_fuzz.exs /tmp/floats.tsv
```

The totals above are the 2026-10-21 run against the grown corpus;
the programme ledger (git.pp-ng `RESULTS.md` §1.6) records both this
run and the original spike run (863/863 · 1,029 · 3,231 · 16,290)
against the smaller corpus.

## Siblings

- **git.pp-ng** — the spec, the TypeScript hub, the Python referee,
  and the conformance corpus this port is measured against:
  https://github.com/patchwork-quilt/git.pp-ng
- **gitpp-action** — the fold in your own CI, as an advisory check:
  https://github.com/patchwork-quilt/gitpp-action
- **gitpp-app** — the GitHub App that posts derived state as Checks:
  https://github.com/patchwork-quilt/gitpp-app
- **outbound-scanner** — a pre-send egress fence for agent harnesses:
  https://github.com/patchwork-quilt/outbound-scanner

## License

MIT © 2026 SuperInstance (see `LICENSE`).
