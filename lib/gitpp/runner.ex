defmodule Gitpp.Runner do
  @moduledoc """
  Conformance runner: the BEAM twin of conformance/runner.ts. Reads a
  cases.json (as written by conformance/harness.py), runs the Elixir fold,
  and writes results in the same shape: per case, the derive output, the
  verify_checkpoint answer for each probe, witness freshness, and the
  closure-root digest for every applied id.

  Usage: mix run conformance/runner.exs -- <cases.json> <results.json>
  """

  alias Gitpp.Fold

  def main([cases_path, results_path]) do
    cases = cases_path |> File.read!() |> :json.decode()

    results =
      Enum.map(cases, fn c ->
        records = c["records"]

        verify =
          Enum.map(c["probes"] || [], fn p ->
            checkpoint =
              %{"at" => p["at"], "state" => p["state"]}
              |> then(fn cp ->
                if Map.has_key?(p, "closureRoot"),
                  do: Map.put(cp, "closureRoot", p["closureRoot"]),
                  else: cp
              end)

            Fold.verify_checkpoint(records, checkpoint)
          end)

        derived = Fold.derive(records)

        roots =
          Map.new(derived["order"], fn id -> {id, Fold.checkpoint_root(records, id)} end)

        %{
          "name" => c["name"],
          "derive" => derived,
          "verify" => verify,
          "freshness" => Fold.witness_freshness(records),
          "roots" => roots
        }
      end)

    File.write!(results_path, :json.encode(results) |> IO.iodata_to_binary())
    IO.puts("runner (elixir): #{length(results)} cases")
  end
end
