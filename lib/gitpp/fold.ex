defmodule Gitpp.Fold do
  @moduledoc """
  The git.pp fold, implemented from DESIGN.md only (doc-only discipline: this
  port was written against the public DESIGN.md + docs/CHECKPOINT-V2.md +
  docs/FRONTIER-CHECKPOINTS.md + the witness-freshness formula in
  docs/ENGINEERING.md, never against the TypeScript or Python sources).

  The 2026-11-02 sync (git.pp-ng v0.2.0) keeps that discipline where the
  documents carry the semantics, and follows the corpus where they were
  corrected: the retraction law (docs/RETRACTION-SPIKE.md — dispute +
  settlement, with the contested amendment), the issue-#38 ingest model
  (missing/non-string ids indexed under a content placeholder, orphanhood
  propagating to descendants), and the leaf band as ruled (CHECKPOINT-V2.md
  SS3: integral doubles with |v| < 1e21 spell as exact integer digits;
  ensure_ascii=True). Three of this port's own earlier readings — orphan
  descendants standing, the 1e16 leaf band, literal non-ASCII emission —
  were pinned by its tests and are superseded; the corrections are recorded
  in the affected test files, not silently flipped.

  A record is a map with binary keys as decoded from JSON:
  "id", "parents", "kind", "effects", "reason" (some optional), plus the
  retraction fields "author", "target", "dispute", "resolution" on the
  records that carry them.
  """

  alias Gitpp.Canon

  # Lower is stronger (the referee's CLASS_RANK). Kinds outside the three
  # named classes rank as witnesses: unverifiable intent is observation.
  @class_rank %{"override" => 0, "task" => 1, "witness" => 2}
  @fallback_rank 2
  @meta_kinds ["dispute", "settlement"]

  # ------------------------------------------------------------- helpers

  # Python str() of a JSON scalar, for the coercions the spec performs
  # (parent ids, a leaf's id, a frontier member). Strings pass through;
  # True/False/None keep Python's spellings, not Erlang's.
  defp py_str(v) when is_binary(v), do: v
  defp py_str(v) when is_integer(v), do: Integer.to_string(v)
  defp py_str(v) when is_float(v), do: Canon.python_repr(v)
  defp py_str(true), do: "True"
  defp py_str(false), do: "False"
  defp py_str(nil), do: "None"
  defp py_str(:null), do: "None"
  defp py_str(v), do: to_string(v)

  defp parents_of(rec) do
    case rec["parents"] do
      ps when is_list(ps) -> Enum.map(ps, &py_str/1)
      _ -> []
    end
  end

  defp effects_of(rec) do
    case rec["effects"] do
      eff when is_map(eff) -> eff
      _ -> %{}
    end
  end

  defp kind_of(rec), do: rec["kind"]

  defp rank_of(rec), do: Map.get(@class_rank, kind_of(rec), @fallback_rank)

  # A record's author, if it carries a non-empty string one. Absence means
  # unattributed.
  defp author_of(rec) do
    case rec["author"] do
      a when is_binary(a) and a != "" -> a
      _ -> nil
    end
  end

  # ------------------------------------------------------------- ingest

  @doc """
  Canonicalise one raw record: float64-canonicalise effect values
  (DESIGN.md SS5). Every other field is carried untouched — the
  retraction fields (author / target / dispute / resolution) ride along.
  """
  def canonical_record(rec) do
    case rec["effects"] do
      eff when is_map(eff) ->
        Map.put(rec, "effects", Map.new(eff, fn {k, v} -> {k, Canon.float64_canonicalise(v)} end))

      _ ->
        rec
    end
  end

  # The index key for a record: its id when it is a string, else the
  # missing-id placeholder (issue #38): "missing-id:" + the SHA-256 of the
  # record's canonical content with the id field EXCLUDED — the leaf
  # normalisation minus id. Such a record is held orphan-class: it can
  # never be referenced or applied, and never silently merges with
  # another id-less record.
  defp effective_id(rec) do
    case rec["id"] do
      id when is_binary(id) ->
        id

      _ ->
        normalized = %{
          "parents" => rec |> parents_of() |> Enum.sort(),
          "kind" => kind_of(rec),
          "effects" => leaf_effects(rec),
          "reason" => rec["reason"]
        }

        "missing-id:" <>
          (:crypto.hash(:sha256, Canon.encode!(normalized)) |> Base.encode16(case: :lower))
    end
  end

  # Effects as the leaf sees them: float64-canonicalised; Canon.encode!/1
  # then spells numbers in the leaf domain (leaf_num).
  defp leaf_effects(rec) do
    Map.new(effects_of(rec), fn {k, v} -> {k, Canon.float64_canonicalise(v)} end)
  end

  @doc """
  Index records by effective id. Built in a canonical order so input
  permutation cannot matter: records sort by (effective id, whole-record
  canonical serialisation with any `digest` field removed — a digest is a
  claim ABOUT a record, never content the fold may consult), and the last
  record under each id wins.
  """
  def index(records) do
    records
    |> Enum.sort_by(fn r -> {effective_id(r), index_sort_key(r)} end)
    |> Enum.reduce(%{}, fn r, acc -> Map.put(acc, effective_id(r), r) end)
  end

  defp index_sort_key(rec), do: Canon.dumps!(Map.delete(rec, "digest"))

  defp parents_map(idx),
    do: Map.new(idx, fn {rid, r} -> {rid, parents_of(r)} end)

  # ------------------------------------------------------------- orphans

  # Records excluded from derivation: any ancestor absent, or blocked
  # behind such a record, or in/behind a parent cycle. Computed over ALL
  # records (meta kinds included — the parents graph is kind-blind).
  # Records indexed under a missing-id placeholder are orphans by
  # construction: seeded into the worklist alongside the missing-parent
  # records, so the exclusion propagates to their descendants.
  defp orphan_set(idx, parents) do
    children =
      Enum.reduce(idx, %{}, fn {rid, _}, acc ->
        Enum.reduce(parents[rid], acc, fn p, a ->
          if Map.has_key?(idx, p), do: Map.update(a, p, [rid], &[rid | &1]), else: a
        end)
      end)

    seeds =
      Enum.filter(Map.keys(idx), fn rid ->
        not is_binary(idx[rid]["id"]) or
          Enum.any?(parents[rid], &(not Map.has_key?(idx, &1)))
      end)

    orphan = propagate(seeds, children, MapSet.new(seeds))
    orphan |> MapSet.union(cycle_affected(MapSet.difference(MapSet.new(Map.keys(idx)), orphan), parents))
  end

  defp propagate([], _children, acc), do: acc

  defp propagate([id | rest], children, acc) do
    fresh = Enum.reject(children[id] || [], &MapSet.member?(acc, &1))
    propagate(rest ++ fresh, children, MapSet.union(acc, MapSet.new(fresh)))
  end

  # Nodes that cannot be topologically ordered within `nodes` (in, or
  # blocked behind, a parent cycle).
  defp cycle_affected(nodes, parents) do
    {_order, done} = topo(nodes, parents)
    MapSet.difference(nodes, done)
  end

  # Kahn's algorithm, always taking the smallest ready id: one canonical
  # order. Indegree counts only parents inside the node set, so a subgraph
  # (e.g. the derivation records, whose meta parents are not derivation
  # steps) gets its own canonical order. Returns {order, ordered_set};
  # nodes in/behind cycles are simply never ordered.
  defp topo(nodes, parents) do
    nodes = MapSet.new(nodes)

    indeg =
      Map.new(nodes, fn r ->
        {r, Enum.count(parents[r], &MapSet.member?(nodes, &1))}
      end)

    children =
      Enum.reduce(nodes, %{}, fn r, acc ->
        Enum.reduce(parents[r], acc, fn p, a ->
          if MapSet.member?(nodes, p), do: Map.update(a, p, [r], &[r | &1]), else: a
        end)
      end)

    do_topo(nodes, indeg, children, MapSet.new(), [])
  end

  defp do_topo(nodes, indeg, children, done, acc) do
    ready =
      nodes
      |> Enum.filter(&(not MapSet.member?(done, &1) and indeg[&1] == 0))
      |> Enum.sort()

    case ready do
      [] ->
        {Enum.reverse(acc), done}

      [next | _] ->
        indeg =
          Enum.reduce(children[next] || [], indeg, fn c, d -> Map.update!(d, c, &(&1 - 1)) end)

        do_topo(nodes, indeg, children, MapSet.put(done, next), [next | acc])
    end
  end

  # Full ancestor set of every landed record, memoised in topological
  # order (parents precede children). Computed over the whole landed
  # graph — meta and retracted records included — so ancestry
  # transitivity runs through them exactly as through any record; only
  # candidacy and the cleanliness tallies treat them specially.
  defp ancestor_sets(_idx, parents, landed) do
    {order, _} = topo(landed, parents)

    Enum.reduce(order, %{}, fn rid, acc ->
      anc =
        Enum.reduce(parents[rid], MapSet.new(), fn p, s ->
          case Map.fetch(acc, p) do
            {:ok, pa} -> s |> MapSet.put(p) |> MapSet.union(pa)
            :error -> s
          end
        end)

      Map.put(acc, rid, anc)
    end)
  end

  # ------------------------------------------------- the settlement pass

  # Retraction (dispute + settlement) — FOLD LAW as of Casey's ruling,
  # 2026-11-02 (adopting PR #16 with the contested amendment; see git.pp-ng
  # docs/RETRACTION-SPIKE.md for the design record).
  #
  #   dispute    {target, reason (mandatory), author?} — claims the
  #              target's effects should not stand. While OPEN (unsettled,
  #              settled "rejected", settled by nobody with authority, or
  #              malformed) it changes NOTHING in derivation.
  #   settlement {dispute, resolution: "upheld"|"rejected", author?} —
  #              bites only if AUTHORITATIVE: its author is the target
  #              record's author, or a captain-class author (has authored
  #              an applied — landed, non-orphan — override in this set).
  #              Anonymous settlements never bite.
  #
  # An upheld dispute RETRACTS its target: the target's effects are
  # voided and derivation re-runs, but the target keeps its graph
  # position — it is NOT removed from the set, so its descendants are not
  # orphaned and not auto-disputed; their ancestry still runs through it.
  # A retracted record lends no cleanliness: in descendants' tallies it
  # counts as NEITHER an intent nor a witness ancestor (the bounded
  # stain — floor "counts as nothing"; stacking penalties not taken).
  #
  # THE CONTESTED AMENDMENT (the ruling's condition): when a record is
  # retracted on a ratified accusation — an upheld dispute that its
  # author neither filed nor settled — the retraction is not silent. The
  # record is marked CONTESTED in the retraction surface, with the
  # dispute/settlement provenance. A retraction the author filed or
  # settled themselves is a plain retraction, never "contested", and an
  # unattributed target is never contested.
  #
  # Meta records (dispute/settlement) are never derivation steps: they
  # are excluded from `order`, from candidacy (any `effects` on them are
  # void), and from ancestry tallies, but they remain in the parents
  # graph for orphan/cycle analysis and for ancestry transitivity.
  #
  # Disputes may target meta records too: settled upheld, they VOID the
  # targeted dispute/settlement (a voided settlement never ruled; a
  # voided dispute never bites). Voiding is evaluated on the
  # dispute-dependency graph; a dispute that sits in, or depends on, a
  # voiding cycle has no well-founded settlement basis and is inert
  # (doubt -> no bite).
  #
  # Returns {retracted, statuses, contested}: the set of non-meta record
  # ids whose effects are voided; EVERY dispute id's status
  # ("open" | "upheld" | "rejected" | "inert"); and the contested
  # provenance entries, sorted by (record, dispute).
  defp settlement_pass(idx, orphan) do
    kind = Map.new(idx, fn {rid, r} -> {rid, kind_of(r)} end)
    author = Map.new(idx, fn {rid, r} -> {rid, author_of(r)} end)

    captains =
      for {rid, _r} <- idx,
          kind[rid] == "override",
          not MapSet.member?(orphan, rid),
          author[rid] != nil,
          into: MapSet.new(),
          do: author[rid]

    # Well-formed disputes: target names a record in the set, reason is a
    # non-empty string. A dispute that never landed (orphan) is inert.
    target_of =
      Enum.reduce(idx, %{}, fn {rid, r}, acc ->
        tgt = r["target"]
        reason = r["reason"]

        if kind[rid] == "dispute" and is_binary(tgt) and Map.has_key?(idx, tgt) and
             is_binary(reason) and reason != "" do
          Map.put(acc, rid, tgt)
        else
          acc
        end
      end)

    live = target_of |> Map.keys() |> Enum.reject(&MapSet.member?(orphan, &1)) |> MapSet.new()

    # Candidate settlements per dispute: well-formed (names a dispute,
    # resolution in domain), landed (not orphan), attributed, and
    # authoritative for that dispute.
    settlements_on =
      Enum.reduce(idx, %{}, fn {rid, r}, acc ->
        d = r["dispute"]

        cond do
          kind[rid] != "settlement" -> acc
          MapSet.member?(orphan, rid) -> acc
          author[rid] == nil -> acc
          not (is_binary(d) and Map.has_key?(target_of, d)) -> acc
          r["resolution"] not in ["upheld", "rejected"] -> acc
          author[rid] == author[target_of[d]] or MapSet.member?(captains, author[rid]) ->
            Map.update(acc, d, [rid], &[rid | &1])

          true ->
            acc
        end
      end)

    # Dispute-dependency graph: d depends on every dispute whose status
    # decides whether d or one of d's candidate settlements is voided.
    dep_map =
      Map.new(live, fn d ->
        deps =
          Enum.filter(live, fn d2 ->
            target_of[d2] == d or target_of[d2] in (settlements_on[d] || [])
          end)

        {d, MapSet.new(deps)}
      end)

    voided? = fn x, status ->
      Enum.any?(live, fn d2 -> target_of[d2] == x and status[d2] == "upheld" end)
    end

    # Evaluate in dependency order. Whatever cannot be evaluated — it
    # sits in, or depends on, a voiding cycle — has no well-founded
    # settlement basis and stays inert. Each round's ready set is
    # computed against the pre-round statuses; the batch is then
    # processed in id order against the evolving statuses, exactly as
    # the reference loop does.
    {status, ruling_of} =
      eval_disputes(live, dep_map, settlements_on, voided?, idx, %{}, %{})

    statuses =
      Map.new(idx, fn {rid, _} ->
        {rid, status[rid] || "inert"}
      end)
      |> Map.take(Enum.filter(Map.keys(idx), &(kind[&1] == "dispute")))

    retracted =
      for d <- live,
          status[d] == "upheld",
          kind[target_of[d]] not in @meta_kinds,
          into: MapSet.new(),
          do: target_of[d]

    # Contested: the ruling's amendment (see the head comment).
    contested =
      live
      |> Enum.filter(&(status[&1] == "upheld"))
      |> Enum.flat_map(fn d ->
        t = target_of[d]

        cond do
          kind[t] in @meta_kinds -> []
          author[t] == nil -> []
          author[d] == author[t] -> []
          author[ruling_of[d]] == author[t] -> []
          true ->
            s = ruling_of[d]

            [
              %{
                "record" => t,
                "dispute" => d,
                "settlement" => s,
                "disputed_by" => author[d] || :null,
                "settled_by" => author[s]
              }
            ]
        end
      end)
      |> Enum.sort_by(fn e -> {e["record"], e["dispute"]} end)

    {retracted, statuses, contested}
  end

  defp eval_disputes(live, dep_map, settlements_on, voided?, idx, status, ruling_of) do
    remaining = MapSet.difference(live, MapSet.new(Map.keys(status)))

    ready =
      remaining
      |> Enum.filter(&MapSet.subset?(dep_map[&1], MapSet.new(Map.keys(status))))
      |> Enum.sort()

    case ready do
      [] ->
        {status, ruling_of}

      _ ->
        {status, ruling_of} =
          Enum.reduce(ready, {status, ruling_of}, fn d, {st, ro} ->
            if voided?.(d, st) do
              # A voided dispute never bites.
              {Map.put(st, d, "inert"), ro}
            else
              cands = Enum.reject(settlements_on[d] || [], &voided?.(&1, st))

              if cands == [] do
                {Map.put(st, d, "open"), ro}
              else
                ruling = Enum.min(cands)
                {Map.put(st, d, idx[ruling]["resolution"]), Map.put(ro, d, ruling)}
              end
            end
          end)

        eval_disputes(live, dep_map, settlements_on, voided?, idx, status, ruling_of)
    end
  end

  # ------------------------------------------------------------- derive

  @doc """
  derive(records) -> %{"state" => ..., "order" => ..., "conflicts" => ...,
  "orphans" => ...} per DESIGN.md SS1-SS2, with the retraction law
  applied (see settlement_pass/2): meta records are never derivation
  steps, retracted records are never candidates, and neither lends
  cleanliness to descendants' tie-break tallies.
  """
  def derive(records) do
    idx = records |> Enum.map(&canonical_record/1) |> index()
    parents = parents_map(idx)
    orphan = orphan_set(idx, parents)
    {retracted, _statuses, _contested} = settlement_pass(idx, orphan)

    meta =
      idx
      |> Enum.filter(fn {_rid, r} -> kind_of(r) in @meta_kinds end)
      |> MapSet.new(fn {rid, _} -> rid end)

    landed = MapSet.difference(MapSet.new(Map.keys(idx)), orphan)
    applied = MapSet.difference(landed, meta)
    {order, _ordered} = topo(applied, parents)
    ancestors = ancestor_sets(idx, parents, landed)

    setters =
      Enum.reduce(applied, %{}, fn rid, acc ->
        if MapSet.member?(retracted, rid) do
          acc
        else
          Enum.reduce(effects_of(idx[rid]), acc, fn {k, _v}, a ->
            Map.update(a, k, MapSet.new([rid]), &MapSet.put(&1, rid))
          end)
        end
      end)

    {state, conflicts} =
      Enum.reduce(Enum.sort(Map.keys(setters)), {%{}, []}, fn k, {st, cf} ->
        cands = setters[k] |> MapSet.to_list() |> Enum.sort()
        winner = resolve(idx, cands, ancestors, meta, retracted)
        st = Map.put(st, k, effects_of(idx[winner])[k])

        distinct =
          cands
          |> Enum.map(&Canon.value_key(effects_of(idx[&1])[k]))
          |> Enum.uniq()

        cf =
          if length(distinct) >= 2 do
            losers = cands |> Enum.reject(&(&1 == winner)) |> Enum.sort()
            [%{"key" => k, "winner" => winner, "losers" => losers} | cf]
          else
            cf
          end

        {st, cf}
      end)

    %{
      "state" => state,
      "order" => order,
      "conflicts" => Enum.sort_by(conflicts, & &1["key"]),
      "orphans" => orphan |> MapSet.to_list() |> Enum.sort()
    }
  end

  # Per-key resolution (DESIGN.md SS2.4): absolute class precedence,
  # exact maximality within the class (domination runs through meta and
  # retracted records — they keep their graph position), then most intent
  # ancestors -> fewest witness ancestors -> smallest id. The tallies
  # exclude meta and retracted ancestors: a retracted record lends no
  # cleanliness, and meta records are not derivation.
  defp resolve(idx, cands, ancestors, meta, retracted) do
    best = cands |> Enum.map(&rank_of(idx[&1])) |> Enum.min()
    pool = Enum.filter(cands, &(rank_of(idx[&1]) == best))

    dominated =
      Enum.reduce(pool, MapSet.new(), fn d, acc ->
        MapSet.union(acc, MapSet.intersection(ancestors[d], MapSet.new(pool)))
      end)

    maximal = pool |> MapSet.new() |> MapSet.difference(dominated) |> MapSet.to_list()

    Enum.min_by(maximal, fn c ->
      tallied =
        ancestors[c]
        |> MapSet.difference(meta)
        |> MapSet.difference(retracted)

      intent = Enum.count(tallied, &(rank_of(idx[&1]) < @class_rank["witness"]))
      witnesses = Enum.count(tallied, &(rank_of(idx[&1]) == @class_rank["witness"]))
      {-intent, witnesses, c}
    end)
  end

  @doc """
  retraction_status(records) -> %{"disputes" => %{id => status},
  "retracted" => [id], "contested" => [entry]}: the settlement pass as
  data — a sibling surface to witness_freshness, not a change to
  derive()'s output shape. Status is "open" (no authoritative ruling
  yet), "upheld"/"rejected" (the smallest-id authoritative, unvoided
  settlement's ruling), or "inert" (malformed, orphaned, voided, or
  cycle-entangled — the dispute cannot bite). Each contested entry is
  %{"record", "dispute", "settlement", "disputed_by", "settled_by"}: the
  provenance of a retraction the target's author neither filed nor
  settled (Casey's contested amendment, 2026-11-02). Pure function of
  the record set, like derive().
  """
  def retraction_status(records) do
    idx = records |> Enum.map(&canonical_record/1) |> index()
    parents = parents_map(idx)
    orphan = orphan_set(idx, parents)
    {retracted, statuses, contested} = settlement_pass(idx, orphan)

    %{
      "disputes" => statuses,
      "retracted" => retracted |> MapSet.to_list() |> Enum.sort(),
      "contested" => contested
    }
  end

  # ------------------------------------------------- witness freshness

  @doc """
  witness_freshness(records) -> %{witnessId => recordsBehind} for applied
  witnesses, where recordsBehind(w) = |applied| - |ancestorsInclusive(w)|
  and the inclusive walk descends only through applied records
  (docs/ENGINEERING.md, docs/OPEN-QUESTIONS.md SS1b).
  """
  def witness_freshness(records) do
    out = derive(records)
    applied = MapSet.new(out["order"])
    idx = index(records)
    parents = parents_map(idx)
    total = MapSet.size(applied)

    Enum.reduce(out["order"], %{}, fn rid, acc ->
      if kind_of(idx[rid]) == "witness" do
        Map.put(acc, rid, total - MapSet.size(ancestors_incl(rid, parents, applied)))
      else
        acc
      end
    end)
  end

  defp ancestors_incl(start, parents, applied) do
    walk_incl(parents[start] || [], parents, applied, MapSet.new([start]))
  end

  defp walk_incl([], _parents, _applied, seen), do: seen

  defp walk_incl([n | rest], parents, applied, seen) do
    if MapSet.member?(seen, n) or not MapSet.member?(applied, n) do
      walk_incl(rest, parents, applied, seen)
    else
      walk_incl((parents[n] || []) ++ rest, parents, applied, MapSet.put(seen, n))
    end
  end

  # ------------------------------------- checkpoints (v1 + v2 + frontier)

  @doc """
  checkpoint_root(records, at) -> lowercase hex SHA-256 closure root, or nil
  when the closure is incomplete (docs/CHECKPOINT-V2.md).

  Frontier form (docs/FRONTIER-CHECKPOINTS.md): `at` may be a LIST of record
  ids, and the root is computed by the identical construction over the UNION
  of the members' ancestor closures — v2's root was always a digest of a set
  of ids; the singleton closure was just the set it happened to be computed
  over. A one-member list therefore digests byte-identically to the string
  form. A malformed array (empty, duplicate members, non-string members)
  yields nil.
  """
  def checkpoint_root(records, at) do
    idx = index(records)
    parents = parents_map(idx)

    with {:ok, members} <- frontier_members(at),
         %MapSet{} = ids <- closure_multi(idx, parents, members) do
      lines =
        ids
        |> Enum.sort()
        |> Enum.map(fn id -> id <> ":" <> leaf(idx[id]) end)

      :crypto.hash(:sha256, Enum.join(lines, "\n")) |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  end

  # Normalise a checkpoint `at` — string form (v2) or frontier array form —
  # to a member list, or :error if the form is malformed: an empty array,
  # duplicate members, or non-string members. Readers dispatch structurally
  # on the type, and a malformed array fails safe the same way in every
  # caller. A non-string scalar keeps the historical String() coercion of
  # the singleton path.
  defp frontier_members(at) when is_binary(at), do: {:ok, [at]}

  defp frontier_members(at) when is_list(at) do
    cond do
      at == [] -> :error
      Enum.any?(at, &(not is_binary(&1))) -> :error
      length(Enum.uniq(at)) != length(at) -> :error
      true -> {:ok, at}
    end
  end

  defp frontier_members(at), do: {:ok, [py_str(at)]}

  # The set {at} + all transitive parents present in the index; nil if any
  # referenced ancestor (or at itself) is absent.
  defp closure(idx, parents, at) do
    if Map.has_key?(idx, at) do
      walk_closure(idx, parents, [at], MapSet.new())
    else
      nil
    end
  end

  # Union of the ancestor closures of every member; nil if any member is
  # absent or any member's closure is incomplete.
  defp closure_multi(idx, parents, members) do
    Enum.reduce_while(members, MapSet.new(), fn member, acc ->
      case closure(idx, parents, member) do
        nil -> {:halt, nil}
        %MapSet{} = ids -> {:cont, MapSet.union(acc, ids)}
      end
    end)
  end

  defp walk_closure(_idx, _parents, [], acc), do: acc

  defp walk_closure(idx, parents, [id | rest], acc) do
    if MapSet.member?(acc, id) do
      walk_closure(idx, parents, rest, acc)
    else
      if Map.has_key?(idx, id) do
        walk_closure(idx, parents, (parents[id] || []) ++ rest, MapSet.put(acc, id))
      else
        nil
      end
    end
  end

  # The leaf of a record AS PRESENTED (the raw record, not the index
  # form): id via the Python coercion (absent -> ""), parents coerced and
  # sorted (duplicates kept — the serialisation is of the record as it
  # stands), kind and reason raw, effects float64-canonicalised and
  # leaf-number encoded by Canon.
  defp leaf(rec) do
    id =
      cond do
        is_binary(rec["id"]) -> rec["id"]
        not Map.has_key?(rec, "id") -> ""
        true -> py_str(rec["id"])
      end

    normalized = %{
      "id" => id,
      "parents" => rec |> parents_of() |> Enum.sort(),
      "kind" => kind_of(rec),
      "effects" => leaf_effects(rec),
      "reason" => rec["reason"]
    }

    :crypto.hash(:sha256, Canon.encode!(normalized)) |> Base.encode16(case: :lower)
  end

  @doc """
  verify_checkpoint(records, checkpoint):

    * no "closureRoot" in the checkpoint -> v1 boolean (DESIGN.md SS1):
      re-derive over exactly the ancestors of `at` and compare states in
      the float64 number domain.
    * with "closureRoot" -> "VERIFIED" | "STATE-ONLY" | "MISMATCH"
      (docs/CHECKPOINT-V2.md).
    * frontier form (docs/FRONTIER-CHECKPOINTS.md): `at` may be a LIST of
      ids; the covered set is the union of the members' closures, recomputed
      within the presented set — state is derive(covered).state and the root
      is the v2 construction over the union. A malformed array (empty,
      duplicate members, non-string members) answers MISMATCH / false.
  """
  def verify_checkpoint(records, checkpoint) when is_map(checkpoint) do
    expected_root = checkpoint["closureRoot"]
    v2 = expected_root != nil and expected_root != :null
    at = checkpoint["at"]
    want = checkpoint["state"]

    if at == nil or not is_map(want) do
      if v2, do: "MISMATCH", else: false
    else
      case frontier_members(at) do
        :error ->
          if v2, do: "MISMATCH", else: false

        {:ok, members} ->
          idx = index(records)
          parents = parents_map(idx)

          state_ok =
            case closure_multi(idx, parents, members) do
              nil -> false
              ids ->
                subset = Enum.map(Enum.sort(ids), &idx[&1])
                derived = derive(subset)
                Canon.state_equal?(derived["state"], Canon.float64_canonicalise(want))
            end

          cond do
            not v2 -> state_ok
            not state_ok -> "MISMATCH"
            checkpoint_root(records, at) == py_str(expected_root) -> "VERIFIED"
            # RULING — STATE-ONLY stands (Casey, 2026-11-02): when the state
            # matches but the closure root does not, the verdict is
            # "STATE-ONLY" — a different state, reported as state, never
            # accused as MISMATCH, because a closure root alone cannot back
            # that claim up: it proves difference, not substitution.
            #
            # TAILOR-FIT: this branch is the decision point. To rule
            # MISMATCH for the root-differs case instead, the checkpoint
            # format must first pin the closure's size and/or member id-set
            # alongside the root (in every port of this fold), verification
            # must compare the pin here, and only a pin failure — not a root
            # failure — may read as MISMATCH. Until such a pin exists in the
            # format, keep this verdict STATE-ONLY: say only what the record
            # proves. (Same note at the same point in git.pp-ng's fold.py /
            # fold.ts.)
            true -> "STATE-ONLY"
          end
      end
    end
  end

  def verify_checkpoint(_records, _checkpoint), do: false
end
