defmodule Gitpp.SpecBoundaryTest do
  @moduledoc """
  The §3 number boundary, pinned as executable assertions.

  These exist because the port was never in the cross-port leaf fuzz, and
  it diverges on this clause in two different ways (canon.ex:18 and
  canon.ex:140). A green run here means the boundary is right; a red one
  names the exact value that broke.

  The expected leaves are the spec's, cross-checked against the five leaf
  ports that agree 20,043/20,043.
  """
  use ExUnit.Case, async: true
  alias Gitpp.Canon

  defp leaf(x) do
    %{id: "s", kind: "task", parents: [], effects: %{x: x}, reason: nil}
    |> Canon.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  describe "§3 integral float band" do
    # Integral and |v| < 1e21 -> exact integer digits (CHECKPOINT-V2.md
    # §3; the band was RULED upstream 2026-10-20 — "1e21 stands", the
    # 1e16 reading reverted). This suite previously pinned the reverted
    # reading (scientific from 1e16 up); those assertions protected the
    # defect, and the LEAF-BAND corpus family is the receipt.
    test "1e15 is integer form" do
      assert Canon.leaf_number(1.0e15) == "1000000000000000"
    end

    test "9007199254740992.0 (2**53) is integer form" do
      assert Canon.leaf_number(9.007199254740992e15) == "9007199254740992"
    end

    test "1e16 is integer form, not scientific" do
      assert Canon.leaf_number(1.0e16) == "10000000000000000"
    end

    test "1e18 is integer form" do
      assert Canon.leaf_number(1.0e18) == "1000000000000000000"
    end

    test "7.2e20 is integer form (exact digits of the double)" do
      assert Canon.leaf_number(7.2e20) == "720000000000000000000"
    end
  end

  describe "§3 small floats" do
    test "1e-5 is scientific with a zero-padded exponent" do
      assert Canon.leaf_number(1.0e-5) == "1e-05"
    end

    test "2.5e-7 is scientific" do
      assert Canon.leaf_number(2.5e-7) == "2.5e-07"
    end

    test "signed zero is 0" do
      assert Canon.leaf_number(-0.0) == "0"
    end

    test "0.00001 is NOT scientific (|v| >= 1e-4)" do
      assert Canon.leaf_number(1.0e-5 * 10) == "0.0001"
    end
  end
end
