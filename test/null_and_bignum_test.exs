defmodule Gitpp.NullAndBignumTest do
  @moduledoc """
  Two defects that share a shape: a value that a DECODER produces and
  an ENCODER does not know about.

  1. :json.decode on OTP 27 maps a JSON null to the ATOM :null, not to
     nil. `Canon.encode/1` had a clause for it; `Canon.value_key/1` did
     not. The two are parallel paths, and the same fix had reached one
     of them and not the other -- which is the shape of half the
     defects in this project.

     It was reachable from a plain derive/1, because
     state_and_conflicts/3 calls distinct_values?/3 for EVERY candidate
     key, not only for contested ones. An UNCONTESTED null value was
     enough to crash the whole fold.

  2. OTP 27's bignum -> double conversion rounds TOWARD ZERO instead of
     to nearest-even -- via `v * 1.0`, via `:erlang.float/1`, and via
     `v / 1` alike. Every other port in the fleet rounds to
     nearest-even, so the same JSON text encoded to different bytes on
     two platforms: a LEAF divergence, not a formatting one. It was
     found by the mutation pass -- 5 mutants out of 131,499 -- and it
     is invisible to a corpus that never carries a large integer
     literal.
  """
  use ExUnit.Case, async: true
  alias Gitpp.{Canon, Fold}

  describe "JSON null is the atom :null on OTP 27" do
    test "value_key/1 accepts it, exactly as encode/1 already did" do
      assert Canon.value_key(:null) == :null
      assert Canon.value_key(nil) == :null
      # The two must AGREE. A key that says "null" and an encoder that
      # says "null" have to be the same null.
      assert Canon.value_key(:null) == Canon.value_key(nil)
    end

    test "an UNCONTESTED null effect does not crash the fold" do
      records =
        :json.decode(
          ~s([{"id":"issue-1","kind":"task","parents":[],"effects":{"assignee":null},"reason":null}])
        )

      d = Fold.derive(records)
      assert d["order"] == ["issue-1"]
      assert d["orphans"] == []
      assert Map.keys(d["state"]) == ["assignee"]
    end

    test "a CONTESTED null effect does not crash the fold either" do
      records =
        :json.decode(
          ~s([{"id":"a","kind":"task","parents":[],"effects":{"x":null},"reason":null},
               {"id":"b","kind":"task","parents":[],"effects":{"x":null},"reason":null}])
        )

      d = Fold.derive(records)
      # Two records with the SAME value are not a conflict, and a null is
      # a value like any other.
      assert d["conflicts"] == []
    end
  end

  describe "bignum to double rounds to nearest-even" do
    # These are the exact five values the mutation pass found: 3 in the
    # float-mantissa-flip class and 2 in the float-regime class, out of
    # 131,499 mutants. The expected values are CPython's.
    @cases [
      {-62476385540040020000, -6.247638554004002e19},
      {-27970732068485180000, -2.797073206848518e19},
      {30363914016017520000, 3.036391401601752e19},
      {61388347704053060000, 6.138834770405306e19},
      {67830440040673530000, 6.783044004067353e19}
    ]

    for {v, expected} <- @cases do
      test "#{v} converts to the correctly-rounded double" do
        assert Canon.float64_canonicalise(unquote(v)) == unquote(expected)
      end
    end

    test "the native BEAM conversion really is one ulp away, so this is not a no-op" do
      # If the BEAM ever fixes its rounding, this test FAILS and the
      # workaround can be removed. A workaround that silently stops
      # being needed is fine; one that silently stops being exercised
      # is not.
      assert 30363914016017520000 * 1.0 != Canon.float64_canonicalise(30363914016017520000)
    end

    test "a small integer is untouched" do
      assert Canon.float64_canonicalise(42) == 42
      assert Canon.float64_canonicalise(0) == 0
    end
  end
end
