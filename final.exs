alias Gitpp.Fold
IO.puts("toolchain: Elixir #{System.version()} / OTP #{System.otp_release()}")
IO.puts("\n-- closure-root receipt (spec PORTS.md Step 3) --")
recs = :json.decode(File.read!("test/burn_test.exs") |> String.replace(~r/^\s*@records_json\s+"""/, "") |> String.replace(~r/"""\s*$/, ""))
r = Fold.checkpoint_root(recs, "task-c")
IO.puts("checkpoint_root(poc-quilt-1@task-c) = #{r}")
IO.puts("spec receipt                            = 60effe23970d8a5cc837636c44685502361288c1f00577e9addfa10cbd4fc91d")
IO.puts(if r == "60effe23970d8a5cc837636c44685502361288c1f00577e9addfa10cbd4fc91d", do: "  -> MATCH", else: "  -> DIVERGES")
