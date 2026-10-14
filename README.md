# git.pp on the BEAM — a third fold port (Elixir spike)

An Elixir/OTP implementation of the git.pp fold, written **from the public
spec only** (doc-only discipline): `DESIGN.md`, `docs/CHECKPOINT-V2.md`, and
the witness-freshness formula in `docs/ENGINEERING.md` of
[SuperInstance/git.pp-ng](https://github.com/SuperInstance/git.pp-ng). The
TypeScript and Python sources were never read; the Python referee was used
only as the harness uses it — a black-box oracle that computes expected
outputs at run time.

**Result: the full conformance corpus passes.**

```
derive:    863/863 cases identical
verify:    1029/1029 checkpoint probes identical (v1 bool + v2 three-way)
freshness: 3231/3231 witness-freshness checks identical
roots:     16290/16290 closure-root digests identical
three-way pins: 6/6 (VERIFIED / STATE-ONLY / MISMATCH semantics)
float fuzz: 10018 doubles, 0 leaf-encoding mismatches vs CPython
```

## Shape

- `Gitpp.Fold` — the fold as a pure function: records → state, conflicts
  (winner + preserved losers), application order, orphans; plus
  `verify_checkpoint/2` (v1 + v2), `checkpoint_root/2`, `witness_freshness/1`.
- `Gitpp.Canon` — the byte-level dialect layer: float64 canonicalisation at
  ingest (DESIGN.md §5), CPython `json.dumps` canonical encoding
  (sort_keys / ensure_ascii / separators), and the pinned leaf-number
  encoding from CHECKPOINT-V2.md. This module is where cross-port identity
  is earned.
- `Gitpp.Project` — one GenServer per project. Records arrive as messages
  and accumulate in arrival order; the fold ignores that order, which the
  burn test proves: kill the process, let the supervisor restart it empty,
  re-feed the record list (in reverse arrival order), get a byte-identical
  digest. The process is a projection; the record list is the truth.
- `Gitpp.ProjectSupervisor` — one-for-one supervision over a project: the
  restart half of the doctrine. Nothing is recovered from a dead process.

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

Tests (fold pins + burn/restart):

```sh
mix test
```

Full conformance (regenerates `cases.json` with the upstream harness, runs
the BEAM runner, diffs against the Python referee):

```sh
scripts/conformance.sh /path/to/git.pp-ng-clone
```

Float fuzz (leaf-number encoding vs CPython on 10k doubles):

```sh
python3 conformance/float_fuzz.py > /tmp/floats.tsv
mix run conformance/float_fuzz.exs /tmp/floats.tsv
```

## License

MIT © 2026 SuperInstance (see `LICENSE`).
