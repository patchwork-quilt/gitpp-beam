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
      # CORRECTED PIN (2026-11-02): the previous value (83d31b81…) was
      # this port's OWN output under literal non-ASCII emission — a
      # self-generated pin, not a cross-port one. The reference leaf
      # (CHECKPOINT-V2.md §3: ensure_ascii=True) is 9bd5b9b1….
      {%{"id"=>"🚀","kind"=>"task","parents"=>["c"],"effects"=>%{"y"=>1},"reason"=>nil},
       "9bd5b9b1f25b5475fc14fe65a4b11c47f588e31b63223d314f0da6dae1a6e552"}
    ]
    for {r, pin} <- pins do
      assert leaf(r) == pin, "leaf drift for #{r["id"]}"
    end
  end

  test "FIX 1 (corrected): the [1e16, 1e21) band is integer digits, not scientific" do
    # This test previously pinned the opposite — scientific from 1e16 —
    # following a reading of §3 that upstream had already reverted
    # (ruled 2026-10-20: the leaf band is 1e21; integral doubles below
    # it spell as exact integer digits). The LEAF-BAND corpus family is
    # the discriminating evidence; the assertions now pin the ruled form.
    assert Canon.leaf_number(1.0e16) == "10000000000000000"
    assert Canon.leaf_number(1.0000000000000002e16) == "10000000000000002"
    assert Canon.leaf_number(2.0e16) == "20000000000000000"
    refute Canon.leaf_number(1.0e16) =~ ".0"
  end

  test "FIX 2 (corrected): non-ASCII is escaped (ensure_ascii=TRUE)" do
    # §3 pins ensure_ascii=True for the leaf construction; the earlier
    # claim that "the spec forbids" it was this port's own misreading,
    # and the case-4 pin it defended was self-generated (see above).
    assert Canon.encode!(%{"k" => "é"}) == ~S({"k": "\u00e9"})
    assert Canon.encode!(%{"k" => "🚀"}) == ~S({"k": "\ud83d\ude80"})
    # Control characters ARE escaped as well. The port already got this
    # right; the first draft of this assertion was wrong and the test
    # caught ME.
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
    assert Canon.encode!(%{"k" => "🚀"}) == ~S({"k": "\ud83d\ude80"})
  end
end
