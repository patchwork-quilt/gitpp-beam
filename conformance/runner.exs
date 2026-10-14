# Conformance runner entry point (see Gitpp.Runner).
#   mix run conformance/runner.exs -- <cases.json> <results.ex.json>
System.argv() |> Enum.reject(&(&1 == "--")) |> Gitpp.Runner.main()
