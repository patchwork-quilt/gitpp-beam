# Float fuzz: match Canon.leaf_number/1 against the Python oracle TSV
# produced by conformance/float_fuzz.py (literal <TAB> expected-leaf).
[path] = System.argv()

bad =
  path
  |> File.stream!()
  |> Enum.reduce(0, fn line, bad ->
    [literal, expected] = line |> String.trim_trailing("\n") |> String.split("\t")
    {f, ""} = Float.parse(literal)
    got = Gitpp.Canon.leaf_number(f)

    if got == expected do
      bad
    else
      IO.puts("MISMATCH #{literal}: python=#{expected} elixir=#{got}")
      bad + 1
    end
  end)

IO.puts("float fuzz mismatches: #{bad}")
if bad > 0, do: System.halt(1)
