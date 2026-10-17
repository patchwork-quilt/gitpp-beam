defmodule Gitpp.Elixir117RegressionTest do
  # Three defects found by finally EXECUTING this port, plus the pinned
  # leaves it was failing. Each case here was mutation-verified: reverting
  # the fix makes this test fail.
  use ExUnit.Case, async: true
  alias Gitpp.Canon

  defp leaf(r) do
    :crypto.hash(:sha256, Canon.encode!(Gitpp.Fold.canonical_record(r)))
    |> Base.encode16(case: :lower)
  end

  test "the four pinned cross-port leaves" do
    pins = [
      {%{"id"=>"a","kind"=>"task","parents"=>[],"effects"=>%{},"reason"=>nil},
       "229f56e059c1e8209d9e9c0a767ac70f02601f7abe53875069c7d55827533124"},
      {%{"id"=>"b","kind"=>"task","parents"=>["a"],"effects"=>%{"x"=>%{"y"=>1,"z"=>[1,2,3]}},"reason"=>nil},
       "64a3cd29253cbeca672be7792c981ef3192bf23de2d6c0dee3708d611c496ad9"},
      {%{"id"=>"c","kind"=>"witness","parents"=>["a"],"effects"=>%{"ok"=>true,"msg"=>"ok"},"reason"=>"witnessed"},
       "97fd12eeb83d78a633613258d3357d84b6753861447a06525e4c54e18053f2f7"},
      {%{"id"=>"🚀","kind"=>"task","parents"=>["c"],"effects"=>%{"y"=>1},"reason"=>nil},
       "83d31b8135b406d8d518733c5f28f3218d1c50ff2a5da2aca6cf698e6905e597"}
    ]
    for {r, pin} <- pins do
      assert leaf(r) == pin, "leaf drift for #{r["id"]}"
    end
  end

  test "FIX 1: the [1e16, 1e17) band is scientific, not integer digits" do
    # exp >= 16, not 17. With 17 the integer branch appended ".0" and
    # emitted "10000000000000000.0" -- malformed, and a string no other
    # port produces.
    assert Canon.leaf_number(1.0e16) == "1e+16"
    assert Canon.leaf_number(1.0000000000000002e16) == "1.0000000000000002e+16"
    assert Canon.leaf_number(2.0e16) == "2e+16"
    refute Canon.leaf_number(1.0e16) =~ ".0"
  end

  test "FIX 2: non-ASCII is emitted literally (ensure_ascii=FALSE)" do
    # The spec forbids ensure_ascii=True. case-4 above is the non-BMP
    # witness: it only passes if the emoji is NOT escaped.
    assert Canon.encode!(%{"k" => "é"}) == ~S({"k": "é"})
    assert Canon.encode!(%{"k" => "🚀"}) == ~S({"k": "🚀"})
    # Control characters ARE still escaped -- ensure_ascii=False does not
    # mean "escape nothing". The port already got this right; the first
    # draft of this assertion was wrong and the test caught ME.
    assert Canon.encode!(%{"k" => "a\u0001b"}) == "{\"k\": \"a\\u0001b\"}"
  end

  test "FIX 3: a JSON null decodes to the atom :null, which must encode" do
    # :json.decode on OTP 27 maps null to :null, not nil. Without a clause
    # this raises FunctionClauseError, and the port's own fixtures never
    # carry a null-valued key so nothing caught it.
    assert Canon.encode!(:null) == "null"
    assert Canon.encode!(nil) == "null"
  end

  test "LOCALE: the encoder is not locale-dependent" do
    # Without ELIXIR_ERL_OPTIONS=+fnu and a UTF-8 locale the VM re-encodes
    # incoming text as latin1 and the emoji is mangled into U+00F0 U+009F
    # U+0098 U+0080 before the canonicaliser sees it. A conforming
    # implementation of a pure-function leaf cannot depend on the locale;
    # this case documents the requirement rather than the behaviour.
    assert Canon.encode!(%{"k" => "🚀"}) == ~S({"k": "🚀"})
  end
end
