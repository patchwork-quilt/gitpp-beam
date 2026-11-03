defmodule Gitpp.OrphanDescendantTest do
  @moduledoc """
  Orphan semantics, pinned as executable assertions.

  THE RULE (git.pp-ng v0.2.0, the issue-#38 model): a record is an
  orphan if any of its parents is not in the set — and the exclusion
  PROPAGATES: an orphan's descendants are orphans too, as is anything
  in or behind a parent cycle. The fold runs on what stands AFTER
  the exclusion, and every excluded record is named in the orphans.

  This port originally pinned the opposite reading of §5.5 — "the
  orphan's descendants are NOT auto-orphaned" — under which a
  missing-parent record's child still derived. The corpus case
  prop-ghost is the discriminating evidence against that reading:
  g (parent "missing") and h (parent g) are BOTH orphans in the
  reference fold, and h's effect never lands. Two cases below
  ("desc of missing", "missing AND cycle") carry the corrected
  expectations; the other eleven agree under both readings, because
  cycle exclusion propagated even in the old model.

  The failure mode this guards is SILENT: a fold that returns a
  confident, well-formed, WRONG answer instead of crashing.

      [orph (parent "ghost", absent), child (parent "orph")]

      the rule     : order [],        orphans ["child","orph"], state {}
      old reading  : order ["child"], orphans ["orph"],        state {"y": 2}
  """

  use ExUnit.Case, async: true
  alias Gitpp.Fold

  defp rec(id, parents, effects) do
    %{"id" => id, "kind" => "task", "parents" => parents,
      "effects" => effects, "reason" => nil}
  end

  defp check(records, orphans, state) do
    d = Fold.derive(records)
    assert d["orphans"] == orphans, "orphans mismatch"
    assert d["state"] == state, "state mismatch"
  end

  test "clean chain" do
    check([rec("a", [], %{}), rec("b", ["a"], %{"x" => 1})], [], %{"x" => 1})
  end

  test "missing parent" do
    check([rec("a", ["ghost"], %{"x" => 1})], ["a"], %{})
  end

  test "desc of missing" do
    # The load-bearing case, CORRECTED 2026-11-02: the kid's parent
    # exists but is itself an orphan, and the exclusion propagates —
    # the kid is an orphan too and its effect never lands. This is
    # the corpus's prop-ghost shape. (The previous expectation — the
    # kid derives — pinned the superseded reading.)
    check([rec("orph", ["ghost"], %{"x" => 1}), rec("kid", ["orph"], %{"y" => 2})],
      ["kid", "orph"], %{})
  end

  test "2-cycle" do
    check([rec("ca", ["cb"], %{}), rec("cb", ["ca"], %{})], ["ca", "cb"], %{})
  end

  test "desc of 2-cycle" do
    # Rule A misses "down": its parent exists but can never be ordered.
    check([rec("ca", ["cb"], %{}), rec("cb", ["ca"], %{}), rec("down", ["cb"], %{"y" => 3})],
      ["ca", "cb", "down"], %{})
  end

  test "desc^2 of 2-cycle" do
    check([rec("ca", ["cb"], %{}), rec("cb", ["ca"], %{}),
           rec("d1", ["cb"], %{}), rec("d2", ["d1"], %{"y" => 4})],
      ["ca", "cb", "d1", "d2"], %{})
  end

  test "cycle + root" do
    check([rec("ca", ["cb"], %{}), rec("cb", ["ca"], %{}), rec("ok", [], %{"z" => 5})],
      ["ca", "cb"], %{"z" => 5})
  end

  test "two cycles" do
    check([rec("a", ["b"], %{}), rec("b", ["a"], %{}),
           rec("c", ["d"], %{}), rec("d", ["c"], %{})],
      ["a", "b", "c", "d"], %{})
  end

  test "self-loop" do
    check([rec("a", ["a"], %{"x" => 6})], ["a"], %{})
  end

  test "desc of self-loop" do
    check([rec("a", ["a"], %{}), rec("k", ["a"], %{"y" => 7})], ["a", "k"], %{})
  end

  test "diamond" do
    check([rec("r", [], %{}), rec("l", ["r"], %{}), rec("m", ["r"], %{}),
           rec("j", ["l", "m"], %{"x" => 8})],
      [], %{"x" => 8})
  end

  test "cycle + branch" do
    check([rec("a", ["b"], %{}), rec("b", ["a"], %{}),
           rec("t", ["r"], %{}), rec("r", ["t"], %{}), rec("leaf", ["r"], %{"x" => 9})],
      ["a", "b", "leaf", "r", "t"], %{})
  end

  test "missing AND cycle" do
    # mk descends from m (missing parent): propagation excludes it
    # too — corrected alongside "desc of missing" (it previously
    # derived {"w" => 2}).
    check([rec("ca", ["cb"], %{}), rec("cb", ["ca"], %{}),
           rec("m", ["ghost"], %{"q" => 1}), rec("mk", ["m"], %{"w" => 2})],
      ["ca", "cb", "m", "mk"], %{})
  end

  test "the §5.5 counterexample, spelled out" do
    d = Fold.derive([
      rec("ca", ["cb"], %{"x" => "cycle-a"}),
      rec("cb", ["ca"], %{"x" => "cycle-b"}),
      rec("down", ["cb"], %{"y" => "downstream"}),
      rec("ok", [], %{"z" => "fine"})
    ])

    assert d["orphans"] == ["ca", "cb", "down"]
    assert d["state"] == %{"z" => "fine"}
  end
end
