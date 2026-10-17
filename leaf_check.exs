defmodule NullFix do
  # OTP 27 :json.decode maps JSON null -> the ATOM :null. Canon.encode/1
  # only has a nil clause. This adapter restores the convention the rest of
  # the port (and Jason) uses, so the leaf-encoding question can be tested.
  def go(:null), do: nil
  def go(l) when is_list(l), do: Enum.map(l, &go/1)
  def go(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, go(v)} end)
  def go(v), do: v
end

defmodule LeafCheck do
  alias Gitpp.Fold
  alias Gitpp.Canon
  # verbatim body of lib/gitpp/fold.ex leaf/1, via public API only
  def canon_json(record) do
    n = Fold.canonical_record(record)
    %{"id" => n["id"],
      "parents" => n["parents"] |> Enum.uniq() |> Enum.sort(),
      "kind" => n["kind"], "effects" => n["effects"], "reason" => n["reason"]}
    |> Canon.encode!()
  end
end

cases = "/tmp/spec/cross-port-leafs.json" |> File.read!() |> :json.decode() |> NullFix.go()
IO.puts("Elixir #{System.version()} / OTP #{System.otp_release()}")
IO.puts(String.duplicate("=", 96))

results =
  Enum.map(cases["cases"], fn c ->
    cj = LeafCheck.canon_json(c["input"])
    leaf = :crypto.hash(:sha256, cj) |> Base.encode16(case: :lower)
    ok = (cj == c["canon_json"]) and (leaf == c["leaf"])
    v = if ok, do: "PASS", else: "FAIL"
    IO.puts("\n[#{v}] #{c["name"]}")
    IO.puts("  pinned leaf : #{c["leaf"]}")
    IO.puts("  port  leaf  : #{leaf}")
    IO.puts("  canon_json  : #{if cj == c["canon_json"], do: "MATCH", else: "MISMATCH"}")
    unless cj == c["canon_json"] do
      IO.puts("    pinned: #{c["canon_json"]}")
      IO.puts("    port  : #{cj}")
    end
    %{name: c["name"], v: v}
  end)

p = Enum.count(results, &(&1.v == "PASS"))
IO.puts("\n" <> String.duplicate("=", 96))
IO.puts("RESULT: #{p}/#{length(results)} PASS")
IO.puts("VERDICT: #{if p == length(results), do: "PASS", else: "FAIL"}")
