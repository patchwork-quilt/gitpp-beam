defmodule Gitpp.CanonTest do
  use ExUnit.Case, async: true

  alias Gitpp.Canon

  test "leaf-number encoding: the doc's pinned examples (FIX 1)" do
    # docs/CHECKPOINT-V2.md: 1e-5 -> "1e-05" (not JS's 0.00001), zero-padded
    # signed exponents; signed zero collapses to "0".
    assert Canon.leaf_number(1.0e-5) == "1e-05"
    assert Canon.leaf_number(2.5e-7) == "2.5e-07"
    assert Canon.leaf_number(-0.0) == "0"
    assert Canon.leaf_number(0.0) == "0"
    assert Canon.leaf_number(1.5) == "1.5"
    assert Canon.leaf_number(45.0) == "45"
    assert Canon.leaf_number(1.0e-100) == "1e-100"
  end

  test "float64 canonicalisation rounds non-safe integers (DESIGN.md SS5)" do
    assert Canon.float64_canonicalise(9_007_199_254_740_993) == 9_007_199_254_740_992.0
    assert Canon.float64_canonicalise(9_007_199_254_740_991) == 9_007_199_254_740_991
    assert Canon.float64_canonicalise(%{"k" => [9_007_199_254_740_993]}) ==
             %{"k" => [9_007_199_254_740_992.0]}
  end

  test "canonical JSON: sorted keys, Python separators and escapes" do
    assert Canon.encode!(%{"b" => 1, "a" => [true, nil, "x\ny"]}) ==
             ~S({"a": [true, null, "x\ny"], "b": 1})

    # ensure_ascii=FALSE (which the spec requires): non-ASCII is emitted
    # LITERALLY as UTF-8, not as \uXXXX. This assertion previously pinned
    # the ensure_ascii=TRUE behaviour, which the spec forbids, so the test
    # was protecting the defect. Verified against the pinned case-4 leaf:
    #   {"k": "é😀"}  ->  sha256 83d31b81…e597
    assert Canon.encode!(%{"k" => "é😀"}) == ~S({"k": "é😀"})
  end

  test "value equality follows Python: True == 1 == 1.0, False == 0" do
    assert Canon.value_equal?(true, 1)
    assert Canon.value_equal?(false, 0.0)
    refute Canon.value_equal?(true, "1")
    refute Canon.value_equal?(1, "1")
  end
end
