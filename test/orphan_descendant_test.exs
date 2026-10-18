defmodule Gitpp.OrphanDescendantTest do
  @moduledoc """
  Spec §5.5, pinned as executable assertions.

  §5.5 says two things that are easy to get backwards:

    "A record is an orphan if any of its parents is not in the applied
     set."                                  -- the orphan's OWN parent
    "The orphan's descendants are NOT auto-orphaned (the fold runs on
     what stands)."                         -- and nothing propagates
                                               DOWNWARD

  No single natural rule satisfies both. Two of them each get a
  different case wrong:

    rule A  "any parent id is missing from the set"    correct on a
                                                          record whose own
                                                          parent is absent,
                                                          WRONG on an
                                                          orphan's descendants
    rule B  "anything Kahn never emitted"              correct on cycle
                                                          descendants, WRONG
                                                          on an orphan's
                                                          descendants
    rule U3 all three clauses together                correct on both

  The 13 cases below are the DISCRIMINATING SET, and they are the same
  13 the C, C# and Perl ports carry -- so a port that passes them
  agrees with the fleet, and a port that fails them names the rule it
  got wrong.

  The bug these caught was SILENT, which is the worst kind: the fold
  returned a confident, well-formed, WRONG answer instead of crashing.

      [orph (parent "ghost", absent), child (parent "orph")]

      other ports : order ["child"], orphans ["orph"],  state {"z": 7}
      this port   : order [],         orphans ["child","orph"], state {}
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
    # The load-bearing case. The kid's parent EXISTS (it is orphaned, not
    # absent), so the kid is orderable and is NOT an orphan. Rule B
    # regresses this.
    check([rec("orph", ["ghost"], %{"x" => 1}), rec("kid", ["orph"], %{"y" => 2})],
      ["orph"], %{"y" => 2})
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
    check([rec("ca", ["cb"], %{}), rec("cb", ["ca"], %{}),
           rec("m", ["ghost"], %{"q" => 1}), rec("mk", ["m"], %{"w" => 2})],
      ["ca", "cb", "m"], %{"w" => 2})
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
