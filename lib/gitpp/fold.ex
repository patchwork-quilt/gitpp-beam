defmodule Gitpp.Fold do
  @moduledoc """
  The git.pp fold, implemented from DESIGN.md only (doc-only discipline: this
  port was written against the public DESIGN.md + docs/CHECKPOINT-V2.md +
  the witness-freshness formula in docs/ENGINEERING.md, never against the
  TypeScript or Python sources).

  A record is a map with binary keys as decoded from JSON:
  "id", "parents", "kind", "effects", "reason" (some optional).
  """

  alias Gitpp.Canon

  @class_rank %{"witness" => 1, "task" => 2, "override" => 3}

  # ------------------------------------------------------------- ingest

  @doc """
  Canonicalise one raw record: float64-canonicalise effect values
  (DESIGN.md SS5), default missing parents/effects, keep kind and reason raw.
  """
  def canonical_record(r) do
    %{
      "id" => to_string(r["id"]),
      "parents" => Enum.map(r["parents"] || [], &to_string/1),
      "kind" => r["kind"],
      "effects" => Canon.float64_canonicalise(r["effects"] || %{}),
      "reason" => r["reason"]
    }
  end

  @doc "Index canonical records by id."
  def index(records) do
    Enum.reduce(records, %{}, fn r, acc -> Map.put(acc, r["id"], r) end)
  end

  # ------------------------------------------------------------- derive

  @doc """
  derive(records) -> %{"state" => ..., "order" => ..., "conflicts" => ...,
  "orphans" => ...} per DESIGN.md SS1-SS2.
  """
  def derive(records) do
    idx = records |> Enum.map(&canonical_record/1) |> index()
    {order, orphans} = application_order(idx)
    ancestors = ancestor_sets(idx, order)
    {state, conflicts} = state_and_conflicts(idx, order, ancestors)
    %{"state" => state, "order" => order, "conflicts" => conflicts, "orphans" => orphans}
  end

  # Kahn's algorithm, smallest-id-first (Unicode code point == UTF-8 byte
  # order, so plain binary comparison is the code-point order).
  #
  # SPEC 5.5 needs THREE clauses, and the two obvious single-clause rules
  # each get a different case wrong:
  #
  #   rule A  "any parent id is missing from the set"   correct on a
  #                                                        record whose own
  #                                                        parent is absent,
  #                                                        WRONG on an orphan's
  #                                                        descendants
  #   rule B  "anything Kahn never emitted"               correct on cycle
  #                                                        descendants, WRONG
  #                                                        on an orphan's
  #                                                        descendants
  #   rule U3 all three clauses together                 correct on both
  #
  # The bug this fixes was rule B, and it was SILENT: the fold returned a
  # confident, well-formed, WRONG answer rather than crashing.
  #
  #   [orph (parent "ghost", absent), child (parent "orph")]
  #
  #   other ports : order ["child"], orphans ["orph"], state {"z": 7}
  #   this port   : order [],        orphans ["child","orph"], state {}
  #
  # The child's effect was silently LOST. 5.5 says the orphan's descendants
  # are NOT auto-orphaned -- the fold runs on what stands.
  defp application_order(idx) do
    # Clause 1: the APPLIED SET. A record whose OWN parent id does not
    # resolve is not applied. NOTHING PROPAGATES DOWNWARD: an absent
    # parent blocks only the record that NAMES it.
    applicable =
      Map.new(idx, fn {id, r} ->
        {id, Enum.all?(r["parents"], &Map.has_key?(idx, &1))}
      end)

    {order, ordered} = do_kahn(idx, applicable, MapSet.new(), [])

    # Clause 2: the orphans are the records that are not applied, plus
    # the ones that could not be ordered, plus the ones whose parent is
    # applied but never ordered -- a cycle's descendants, which 5.4
    # excludes from the order and 5.5 requires in the orphan list.
    orphans =
      idx
      |> Map.keys()
      |> Enum.filter(fn id ->
        not applicable[id] or
          not MapSet.member?(ordered, id) or
          Enum.any?(idx[id]["parents"], fn p ->
            applicable[p] and not MapSet.member?(ordered, p)
          end)
      end)
      |> Enum.sort()

    {order, orphans}
  end

  # Kahn over the APPLIED set.
  #
  # The readiness test counts only the parents that are THEMSELVES applied.
  # A parent that is present but not applied -- an orphan -- does NOT
  # block its child, because the orphan is excluded from the fold and so
  # the link is dropped. A parent that is absent does not block either.
  defp do_kahn(idx, applicable, applied, acc) do
    ready =
      idx
      |> Enum.filter(fn {id, r} ->
        applicable[id] and
          not MapSet.member?(applied, id) and
          Enum.all?(r["parents"], fn p ->
            not applicable[p] or MapSet.member?(applied, p)
          end)
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case ready do
      [] ->
        {Enum.reverse(acc), applied}

      [next | _] ->
        do_kahn(idx, applicable, MapSet.put(applied, next), [next | acc])
    end
  end

  # Memoised ancestor sets, computed in application order (every parent of an
  # applied record is applied earlier, so one pass suffices).
  defp ancestor_sets(idx, order) do
    Enum.reduce(order, %{}, fn id, acc ->
      # A parent that is not in the APPLIED set contributes NOTHING -- not
      # even itself. An orphan is excluded from the fold, so it is not an
      # ancestor of anything that folds.
      #
      # The previous version did Map.fetch!(acc, p), which RAISES when the
      # parent is an orphan. So the d12 case did not merely lose the
      # child's effect -- it would have crashed here.
      anc =
        Enum.reduce(idx[id]["parents"], MapSet.new(), fn p, s ->
          case Map.fetch(acc, p) do
            {:ok, parents} -> MapSet.put(s, p) |> MapSet.union(parents)
            :error -> s
          end
        end)

      Map.put(acc, id, anc)
    end)
  end

  defp state_and_conflicts(idx, order, ancestors) do
    candidates =
      Enum.reduce(order, %{}, fn id, acc ->
        Enum.reduce(idx[id]["effects"], acc, fn {k, _v}, a ->
          Map.update(a, k, [id], &[id | &1])
        end)
      end)
      |> Map.new(fn {k, ids} -> {k, Enum.reverse(ids)} end)

    Enum.reduce(candidates, {%{}, []}, fn {key, cand_ids}, {state, conflicts} ->
      winner = resolve(idx, cand_ids, ancestors)
      value = idx[winner]["effects"][key]

      conflicts =
        if distinct_values?(idx, cand_ids, key) do
          losers = cand_ids |> Enum.reject(&(&1 == winner)) |> Enum.sort()
          [%{"key" => key, "winner" => winner, "losers" => losers} | conflicts]
        else
          conflicts
        end

      {Map.put(state, key, value), conflicts}
    end)
    |> then(fn {state, conflicts} ->
      {state, Enum.sort_by(conflicts, & &1["key"])}
    end)
  end

  defp distinct_values?(idx, cand_ids, key) do
    cand_ids
    |> Enum.map(&Canon.value_key(idx[&1]["effects"][key]))
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  # Per-key resolution (DESIGN.md SS2.4): absolute class precedence, exact
  # maximality within the class, then most intent ancestors -> fewest witness
  # ancestors -> smallest id.
  defp resolve(idx, cand_ids, ancestors) do
    best_rank = cand_ids |> Enum.map(&class_rank(idx[&1])) |> Enum.max()
    pool = Enum.filter(cand_ids, &(class_rank(idx[&1]) == best_rank))

    maximal =
      Enum.reject(pool, fn c ->
        Enum.any?(pool, fn other -> other != c and MapSet.member?(ancestors[other], c) end)
      end)

    Enum.min_by(maximal, fn c ->
      anc = ancestors[c]

      intent =
        Enum.count(anc, fn a -> idx[a]["kind"] in ["task", "override"] end)

      witnesses = Enum.count(anc, fn a -> idx[a]["kind"] == "witness" end)
      {-intent, witnesses, c}
    end)
  end

  defp class_rank(record), do: Map.get(@class_rank, record["kind"], 0)

  # ------------------------------------------------- witness freshness

  @doc """
  witness_freshness(records) -> %{witnessId => recordsBehind} for applied
  witnesses, where recordsBehind(w) = |applied| - |ancestorsInclusive(w)|
  (docs/ENGINEERING.md, docs/OPEN-QUESTIONS.md SS1b).
  """
  def witness_freshness(records) do
    idx = records |> Enum.map(&canonical_record/1) |> index()
    {order, _orphans} = application_order(idx)
    ancestors = ancestor_sets(idx, order)
    n = length(order)

    Enum.reduce(order, %{}, fn id, acc ->
      if idx[id]["kind"] == "witness" do
        inclusive = MapSet.size(ancestors[id]) + 1
        Map.put(acc, id, n - inclusive)
      else
        acc
      end
    end)
  end

  # ------------------------------------------------- checkpoints (v1 + v2)

  @doc """
  checkpoint_root(records, at) -> lowercase hex SHA-256 closure root, or nil
  when the closure is incomplete (docs/CHECKPOINT-V2.md).
  """
  def checkpoint_root(records, at) do
    idx = records |> Enum.map(&canonical_record/1) |> index()

    case closure(idx, at) do
      nil ->
        nil

      ids ->
        lines =
          ids
          |> Enum.sort()
          |> Enum.map(fn id -> id <> ":" <> leaf(idx[id]) end)

        :crypto.hash(:sha256, Enum.join(lines, "\n")) |> Base.encode16(case: :lower)
    end
  end

  # The set {at} + all transitive parents present in the index; nil if any
  # referenced ancestor (or at itself) is absent.
  defp closure(idx, at) do
    if Map.has_key?(idx, at) do
      walk_closure(idx, [at], MapSet.new())
    else
      nil
    end
  end

  defp walk_closure(_idx, [], acc), do: acc

  defp walk_closure(idx, [id | rest], acc) do
    if MapSet.member?(acc, id) do
      walk_closure(idx, rest, acc)
    else
      case Map.fetch(idx, id) do
        :error -> nil
        {:ok, r} -> walk_closure(idx, r["parents"] ++ rest, MapSet.put(acc, id))
      end
    end
  end

  defp leaf(record) do
    normalized = %{
      "id" => record["id"],
      "parents" => record["parents"] |> Enum.uniq() |> Enum.sort(),
      "kind" => record["kind"],
      "effects" => record["effects"],
      "reason" => record["reason"]
    }

    :crypto.hash(:sha256, Canon.encode!(normalized)) |> Base.encode16(case: :lower)
  end

  @doc """
  verify_checkpoint(records, checkpoint):

    * no "closureRoot" in the checkpoint -> v1 boolean (DESIGN.md SS1):
      re-derive over exactly the ancestors of `at` and compare states in the
      float64 number domain.
    * with "closureRoot" -> "VERIFIED" | "STATE-ONLY" | "MISMATCH"
      (docs/CHECKPOINT-V2.md).
  """
  def verify_checkpoint(records, checkpoint) do
    idx = records |> Enum.map(&canonical_record/1) |> index()
    at = checkpoint["at"]
    claimed = checkpoint["state"]

    state_matches =
      is_binary(at) and Map.has_key?(idx, at) and is_map(claimed) and
        closure_state_matches?(idx, at, claimed)

    if Map.has_key?(checkpoint, "closureRoot") and checkpoint["closureRoot"] != nil do
      cond do
        not state_matches -> "MISMATCH"
        checkpoint_root(records, at) == checkpoint["closureRoot"] -> "VERIFIED"
        true -> "STATE-ONLY"
      end
    else
      state_matches
    end
  end

  defp closure_state_matches?(idx, at, claimed) do
    case closure(idx, at) do
      nil ->
        false

      ids ->
        subset = Enum.map(ids, &idx[&1])
        derived = derive(subset)
        Canon.state_equal?(derived["state"], Canon.float64_canonicalise(claimed))
    end
  end
end
