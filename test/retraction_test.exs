defmodule Gitpp.RetractionTest do
  @moduledoc """
  The retraction law (dispute + settlement, with the contested
  amendment — git.pp-ng v0.2.0, Casey's ruling 2026-11-02), pinned as
  executable assertions on both surfaces: derive() (a ratified dispute
  voids the target's effects; an unratified one changes NOTHING) and
  retraction_status() (statuses, the retracted set, and the contested
  markings with their provenance).

  The full corpus — 34 ret-* cases, 258 sprinkled inertness variants,
  302 dispute statuses, 8 contested markings — is diffed against the
  reference by conformance/differ.py; these tests are the port's own
  executable summary of the law's shape.
  """
  use ExUnit.Case, async: true
  alias Gitpp.Fold

  # The shared authored base, mirroring the corpus's design-duel shape:
  # e beats d for k ONLY because e's ancestry runs through c (intent
  # 2 vs 1). Retracting c must flip k to d.
  defp base do
    [
      %{"id" => "g", "parents" => [], "kind" => "task",
        "effects" => %{"k" => 0}, "author" => "amy"},
      %{"id" => "c", "parents" => ["g"], "kind" => "task",
        "effects" => %{"x" => "bad", "k" => 5}, "author" => "amy"},
      %{"id" => "e", "parents" => ["c"], "kind" => "task",
        "effects" => %{"k" => "e-val"}, "author" => "bob"},
      %{"id" => "d", "parents" => ["g"], "kind" => "task",
        "effects" => %{"k" => "d-val"}, "author" => "bob"},
      %{"id" => "ov", "parents" => ["g"], "kind" => "override",
        "effects" => %{"z" => 1}, "author" => "cap"}
    ]
  end

  defp dispute(id, parents, target, author) do
    %{"id" => id, "parents" => parents, "kind" => "dispute",
      "effects" => %{}, "target" => target, "reason" => "filed in error",
      "author" => author}
  end

  defp settlement(id, parents, dispute_id, resolution, author) do
    %{"id" => id, "parents" => parents, "kind" => "settlement",
      "effects" => %{}, "dispute" => dispute_id, "resolution" => resolution,
      "author" => author}
  end

  test "an open dispute changes nothing" do
    recs = base() ++ [dispute("dsp", ["c"], "c", "bob")]
    d = Fold.derive(recs)
    assert d["state"] == %{"k" => "e-val", "x" => "bad", "z" => 1}
    rs = Fold.retraction_status(recs)
    assert rs["disputes"] == %{"dsp" => "open"}
    assert rs["retracted"] == []
    assert rs["contested"] == []
  end

  test "a settlement by nobody with authority changes nothing" do
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "bob"),
         settlement("stl", ["dsp"], "dsp", "upheld", "mallory")]

    assert Fold.derive(recs)["state"]["x"] == "bad"
    assert Fold.retraction_status(recs)["disputes"] == %{"dsp" => "open"}
  end

  test "an anonymous settlement never bites" do
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "bob"),
         %{"id" => "stl", "parents" => ["dsp"], "kind" => "settlement",
           "effects" => %{}, "dispute" => "dsp", "resolution" => "upheld"}]

    assert Fold.retraction_status(recs)["disputes"] == %{"dsp" => "open"}
    assert Fold.derive(recs)["state"]["x"] == "bad"
  end

  test "self-retraction: the author settles her own record upheld" do
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "bob"),
         settlement("stl", ["dsp"], "dsp", "upheld", "amy")]

    d = Fold.derive(recs)
    # c's effects are voided: x is gone and k flips to d.
    assert d["state"] == %{"k" => "d-val", "z" => 1}
    rs = Fold.retraction_status(recs)
    assert rs["disputes"] == %{"dsp" => "upheld"}
    assert rs["retracted"] == ["c"]
    # The author settled it herself: never contested.
    assert rs["contested"] == []
  end

  test "the author rebuts: her own rejected settlement leaves the record standing" do
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "mallory"),
         settlement("stl", ["dsp"], "dsp", "rejected", "amy")]

    assert Fold.derive(recs)["state"]["x"] == "bad"
    assert Fold.retraction_status(recs)["disputes"] == %{"dsp" => "rejected"}
  end

  test "a captain's ratification of a stranger's accusation is CONTESTED, with provenance" do
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "mallory"),
         settlement("stl", ["dsp"], "dsp", "upheld", "cap")]

    assert Fold.derive(recs)["state"] == %{"k" => "d-val", "z" => 1}
    rs = Fold.retraction_status(recs)
    assert rs["retracted"] == ["c"]

    assert rs["contested"] == [
             %{"record" => "c", "dispute" => "dsp", "settlement" => "stl",
               "disputed_by" => "mallory", "settled_by" => "cap"}
           ]
  end

  test "an anonymous accuser, ratified: contested, disputed_by is null" do
    recs =
      base() ++
        [%{"id" => "dsp", "parents" => ["c"], "kind" => "dispute",
           "effects" => %{}, "target" => "c", "reason" => "filed in error"},
         settlement("stl", ["dsp"], "dsp", "upheld", "cap")]

    assert Fold.retraction_status(recs)["contested"] == [
             %{"record" => "c", "dispute" => "dsp", "settlement" => "stl",
               "disputed_by" => :null, "settled_by" => "cap"}
           ]
  end

  test "the author files, the captain settles: her own accusation is never contested" do
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "amy"),
         settlement("stl", ["dsp"], "dsp", "upheld", "cap")]

    rs = Fold.retraction_status(recs)
    assert rs["retracted"] == ["c"]
    assert rs["contested"] == []
  end

  test "meta records never derive: a dispute's own effects are void" do
    dsp = %{"id" => "dsp", "parents" => ["c"], "kind" => "dispute",
            "effects" => %{"x" => "from-dispute", "sneak" => 1},
            "target" => "c", "reason" => "filed in error", "author" => "bob"}
    d = Fold.derive(base() ++ [dsp])
    assert d["state"]["x"] == "bad"
    refute Map.has_key?(d["state"], "sneak")
    refute "dsp" in d["order"]
  end

  test "an orphaned dispute is inert; an orphaned settlement leaves its dispute open" do
    recs =
      base() ++
        [dispute("dsp", ["ghost"], "c", "bob"),
         settlement("stl", ["dsp"], "dsp", "upheld", "cap")]

    assert Fold.retraction_status(recs)["disputes"] == %{"dsp" => "inert"}

    recs2 =
      base() ++
        [dispute("dsp", ["c"], "c", "bob"),
         settlement("stl", ["ghost"], "dsp", "upheld", "cap")]

    assert Fold.retraction_status(recs2)["disputes"] == %{"dsp" => "open"}
    assert Fold.derive(recs2)["state"]["x"] == "bad"
  end

  test "a malformed dispute (no reason) is inert" do
    dsp = %{"id" => "dsp", "parents" => ["c"], "kind" => "dispute",
            "effects" => %{}, "target" => "c", "author" => "bob"}
    rs = Fold.retraction_status(base() ++ [dsp])
    assert rs["disputes"] == %{"dsp" => "inert"}
  end

  test "a voided settlement never ruled: disputing the settlement reopens the dispute" do
    # Mirrors the corpus's ret-dispute-of-settlement: c's author settles
    # the dispute against her own record upheld; a second dispute
    # targets THAT settlement, and its own author settles it upheld —
    # the settlement is voided, so the first dispute never bit.
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "bob"),
         settlement("stl", ["dsp"], "dsp", "upheld", "amy"),
         dispute("dsp2", ["stl"], "stl", "bob"),
         settlement("stl2", ["dsp2"], "dsp2", "upheld", "amy")]

    rs = Fold.retraction_status(recs)
    assert rs["disputes"] == %{"dsp" => "open", "dsp2" => "upheld"}
    # The original retraction falls with its settlement: x stands.
    assert Fold.derive(recs)["state"]["x"] == "bad"
    assert rs["retracted"] == []
  end

  test "a retracted witness leaves the state but keeps its freshness seat" do
    recs = [
      %{"id" => "g", "parents" => [], "kind" => "task",
        "effects" => %{}, "author" => "amy"},
      %{"id" => "w", "parents" => ["g"], "kind" => "witness",
        "effects" => %{"env.disk" => 93}, "author" => "bob"},
      %{"id" => "t", "parents" => ["g"], "kind" => "task",
        "effects" => %{"k" => 1}, "author" => "amy"},
      %{"id" => "ov", "parents" => ["g"], "kind" => "override",
        "effects" => %{"z" => 1}, "author" => "cap"},
      dispute("dsp", ["w"], "w", "amy"),
      settlement("stl", ["dsp"], "dsp", "upheld", "cap")
    ]

    d = Fold.derive(recs)
    refute Map.has_key?(d["state"], "env.disk")
    assert Fold.retraction_status(recs)["retracted"] == ["w"]
    # The record itself stands — it is still an applied witness.
    assert Map.has_key?(Fold.witness_freshness(recs), "w")
  end

  test "determinism: the contested surface is a pure function of the set" do
    recs =
      base() ++
        [dispute("dsp", ["c"], "c", "mallory"),
         settlement("stl", ["dsp"], "dsp", "upheld", "cap")]

    assert Fold.retraction_status(Enum.reverse(recs)) == Fold.retraction_status(recs)
    assert Fold.derive(Enum.reverse(recs)) == Fold.derive(recs)
  end
end
