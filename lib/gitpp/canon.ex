defmodule Gitpp.Canon do
  @moduledoc """
  Canonical JSON encoding with CPython `json.dumps` semantics, as pinned by
  docs/CHECKPOINT-V2.md: sort_keys=True (Unicode code point), ensure_ascii=True,
  separators=(", ", ": "), and the leaf-number encoding (float64 domain):

    * an integral value with |v| < 1e21 -> its exact integer digits
    * -0.0 -> 0
    * every other finite value -> Python's repr float form (shortest
      round-trip digits; scientific with a sign-prefixed, >=2-digit
      zero-padded exponent when decpt <= -4 or decpt > 16 in 0.D x 10^decpt
      terms)

  Also hosts the float64 canonicalisation applied at record ingest
  (DESIGN.md SS5: integers outside the JS safe range round to float64).
  """

  @json_safe_integer 9_007_199_254_740_991
  # The §3 leaf-encoding boundary. Distinct from @json_safe_integer above,
  # which decides whether an integer survives a float64 round trip. The
  # leaf band ends at 1e21 (CHECKPOINT-V2.md §3; ruled 2026-10-20 —
  # "Leaf boundary RULING: 1e21 stands", the 1e16 reading reverted
  # upstream): an integral double with |v| < 1e21 spells as its exact
  # integer digits. This module previously carried 1.0e16 here, which
  # sent every integral double in [1e16, 1e21) down the repr path and
  # diverged from the reference leaf on the whole LEAF-BAND family.
  @leaf_integer_band 1.0e21

  # ------------------------------------------------------------------ ingest

  @doc """
  Float64-canonicalise a JSON value recursively: integers with
  |n| > 2^53-1 become the nearest IEEE-754 double. Everything else is
  structurally preserved.
  """
  def float64_canonicalise(v) when is_integer(v) do
    if abs(v) > @json_safe_integer, do: bignum_to_float(v), else: v
  end

  def float64_canonicalise(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {k, float64_canonicalise(val)} end)
  end

  def float64_canonicalise(v) when is_list(v), do: Enum.map(v, &float64_canonicalise/1)
  def float64_canonicalise(v), do: v

  # A bignum to the nearest IEEE-754 double, ROUNDED TO NEAREST EVEN.
  #
  # OTP 27's own bignum -> double conversion -- via `v * 1.0`, via
  # `:erlang.float/1`, and via `v / 1` alike -- rounds TOWARD ZERO
  # instead of to nearest-even, so it lands one ulp away from the
  # correctly-rounded double. CPython, and every other port in the
  # fleet, round to nearest-even. The same JSON text therefore encoded
  # to different bytes on two platforms, which is a LEAF divergence
  # rather than a formatting one.
  #
  #   v = 30363914016017520000
  #     BEAM  v * 1.0   ->  3.0363914016017523e19
  #     CPython          ->  3.036391401601752e+19
  #
  # The fix goes through the DECIMAL STRING, which is exact for a
  # bignum, and parses it with binary_to_float -- which is strtod, and
  # strtod is correctly rounded. The exact decimal digits are the
  # bridge between a BEAM that cannot round correctly and a C library
  # that can.
  defp bignum_to_float(v) do
    :erlang.binary_to_float(Integer.to_string(v) <> ".0")
  end

  # ------------------------------------------------------------- value class

  @doc """
  A canonical key for a JSON value under CPython equality semantics, used for
  conflict distinctness: True == 1 == 1.0 and False == 0 == 0.0 collapse into
  one numeric class; strings, null, lists and dicts are their own classes
  (recursively). Assumes the value is already float64-canonicalised.
  """
  def value_key(v) when is_boolean(v), do: {:num, if(v, do: 1.0, else: 0.0)}
  # The same one-ulp problem, and the same fix. value_key is the
  # CONFLICT-DISTINCTNESS key, so a value that differs by one ulp is a
  # value the fold treats as different -- and a fold that disagrees
  # with the reference about whether two values are the same is a
  # divergence that no leaf test would ever see.
  def value_key(v) when is_integer(v) do
    if abs(v) > @json_safe_integer, do: {:num, bignum_to_float(v)}, else: {:num, v * 1.0}
  end
  def value_key(v) when is_float(v), do: {:num, v}
  def value_key(nil), do: :null

  # :json.decode on OTP 27 maps a JSON null to the atom :null, not to nil.
  #
  # The encode path already has a clause for :null. The value_key path
  # did not, and the two are parallel -- so the SAME fix was applied to
  # one and not the other. That is the shape of half the defects in this
  # project: a fix that reached one of two places that needed it.
  #
  # It is reachable from a plain derive/1, and it is SILENT in the worst
  # way: state_and_conflicts/3 calls distinct_values?/3 for EVERY
  # candidate key, not only for contested ones, so an UNCONTESTED null
  # value is enough to crash the whole fold.
  def value_key(:null), do: :null
  def value_key(v) when is_binary(v), do: {:str, v}

  def value_key(v) when is_list(v), do: {:list, Enum.map(v, &value_key/1)}

  def value_key(v) when is_map(v) do
    {:map, v |> Enum.map(fn {k, val} -> {k, value_key(val)} end) |> Enum.sort()}
  end

  @doc "Python-equality comparison of two float64-canonicalised JSON values."
  def value_equal?(a, b), do: value_key(a) == value_key(b)

  @doc "Python-equality comparison of two JSON objects (state maps)."
  def state_equal?(a, b) when is_map(a) and is_map(b) do
    map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and value_equal?(v, Map.fetch!(b, k)) end)
  end

  def state_equal?(_a, _b), do: false

  # ------------------------------------------------------- canonical encoding

  @doc """
  Encode a JSON value as canonical bytes (iodata) per the module doc.
  Maps must have binary keys. Numbers are leaf-encoded.
  """
  def encode(v) when is_map(v) do
    inner =
      v
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, val} -> [encode_string(k), ": ", encode(val)] end)
      |> Enum.intersperse(", ")

    ["{", inner, "}"]
  end

  def encode(v) when is_list(v) do
    ["[", v |> Enum.map(&encode/1) |> Enum.intersperse(", "), "]"]
  end

  def encode(v) when is_binary(v), do: encode_string(v)
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(nil), do: "null"

  # :json.decode on OTP 27 maps a JSON null to the atom :null, not to nil.
  # Without this clause any record carrying an explicit null crashes with a
  # FunctionClauseError -- and the port's own fixtures never carry a
  # null-valued key, so nothing caught it. The cross-port cases are the
  # first records that do.
  def encode(:null), do: "null"
  # Integers print as their exact digits — CPython's json.dumps of an
  # int, and the leaf form of a leaf-domain integer alike. Values that
  # needed the float64 domain were canonicalised at ingest (a JSON
  # integer beyond 2**53-1 arrives here as a float, never as a bignum),
  # and an integer produced from an integral double < 1e21 is exact by
  # construction, so no band rerouting belongs here.
  def encode(v) when is_integer(v), do: Integer.to_string(v)
  def encode(v) when is_float(v), do: leaf_number(v)

  def encode!(v), do: v |> encode() |> IO.iodata_to_binary()

  # ------------------------------------------------------- json.dumps form

  @doc """
  CPython `json.dumps` of a value: sort_keys=True, ensure_ascii=True,
  default separators (", ", ": "), integers as exact digits, floats in
  repr form — NOT the leaf encoding (json.dumps(45.0) is "45.0"; an
  integral double in [1e16, 1e21) is "1e+16", where the leaf spells the
  exact digits). Used for the fold's duplicate-id index sort key: the
  one place a whole-record serialisation must match the reference
  byte-for-byte without leaf-number rewriting.
  """
  def dumps!(v), do: v |> encode_dumps() |> IO.iodata_to_binary()

  def encode_dumps(v) when is_map(v) do
    inner =
      v
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, val} -> [encode_string(k), ": ", encode_dumps(val)] end)
      |> Enum.intersperse(", ")

    ["{", inner, "}"]
  end

  def encode_dumps(v) when is_list(v) do
    ["[", v |> Enum.map(&encode_dumps/1) |> Enum.intersperse(", "), "]"]
  end

  def encode_dumps(v) when is_binary(v), do: encode_string(v)
  def encode_dumps(true), do: "true"
  def encode_dumps(false), do: "false"
  def encode_dumps(nil), do: "null"
  def encode_dumps(:null), do: "null"
  def encode_dumps(v) when is_integer(v), do: Integer.to_string(v)
  def encode_dumps(v) when is_float(v), do: dumps_float(v)

  # json.dumps of a float is repr: -0.0 keeps its sign here (the leaf
  # collapses it to "0"; a serialisation may not).
  defp dumps_float(v) do
    if v == 0.0 do
      <<sign::1, _rest::63>> = <<v::float-64>>
      if sign == 1, do: "-0.0", else: "0.0"
    else
      python_repr(v)
    end
  end

  # Python json string escaping with ensure_ascii=True, which is what
  # §3 pins for the leaf construction (json.dumps(..., ensure_ascii=True,
  # ...)): \", \\, the short escapes, and every code point outside
  # 0x20..0x7E as \uXXXX (surrogate pairs above the BMP).
  #
  # This previously emitted non-ASCII literally as UTF-8, under a comment
  # claiming the spec forbids ensure_ascii=True. It does not: §3 spells
  # ensure_ascii=True, both reference ports implement it, and the
  # "pinned" non-ASCII leaf this reading defended (83d31b81…) was this
  # port's own output, not a cross-port value — the reference leaf for
  # the same record is 9bd5b9b1…. The tests that pinned the literal
  # reading are corrected in the same change that fixes this clause.
  defp encode_string(s) do
    escaped =
      for <<cp::utf8 <- s>>, into: "" do
        case cp do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          ?\n -> "\\n"
          ?\r -> "\\r"
          ?\t -> "\\t"
          0x08 -> "\\b"
          0x0C -> "\\f"
          cp when cp < 0x20 -> unicode_escape(cp)
          cp when cp < 0x7F -> <<cp::utf8>>
          cp -> unicode_escape(cp)
        end
      end

    "\"" <> escaped <> "\""
  end

  defp unicode_escape(cp) when cp <= 0xFFFF do
    "\\u" <> (cp |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase())
  end

  defp unicode_escape(cp) do
    v = cp - 0x10000
    hi = 0xD800 + div(v, 0x400)
    lo = 0xDC00 + rem(v, 0x400)
    unicode_escape(hi) <> unicode_escape(lo)
  end

  # ------------------------------------------------------------ leaf numbers

  @doc """
  The leaf-number encoding for a float64: exact integer digits when integral
  and |v| < 1e21, "0" for signed zero, otherwise Python repr form.
  """
  def leaf_number(v) when is_float(v) do
    cond do
      v == 0.0 -> "0"
      v == trunc(v) and abs(v) < @leaf_integer_band -> Integer.to_string(trunc(v))
      true -> python_repr(v)
    end
  end

  @doc """
  Python `repr` of a non-integral finite float: shortest round-trip digits
  rendered fixed when -4 < decpt <= 17 (decpt in 0.D x 10^decpt convention),
  scientific otherwise with a signed, >=2-digit exponent.
  """
  def python_repr(v) when is_float(v) do
    {digits, decpt} = shortest_digits(abs(v))
    rendered = render_repr(digits, decpt)
    if v < 0, do: "-" <> rendered, else: rendered
  end

  defp render_repr(digits, decpt) do
    exp = decpt - 1

    # CPython's repr switches to scientific notation when the decimal
    # exponent is < -4 or >= 16. This said 17, which left the whole
    # [1e16, 1e17) band emitting integer digits -- and then the integer
    # branch below appended ".0", producing "10000000000000000.0", a
    # malformed number string that no other port emits and that does not
    # round-trip. One character, and it is the difference between a
    # conformant leaf and a corrupt one.
    if exp < -4 or exp >= 16 do
      mantissa =
        case digits do
          <<d>> -> <<d>>
          <<d, rest::binary>> -> <<d, ?., rest::binary>>
        end

      sign = if exp < 0, do: "-", else: "+"
      digits_str = exp |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
      mantissa <> "e" <> sign <> digits_str
    else
      fixed_form(digits, decpt)
    end
  end

  defp fixed_form(digits, decpt) do
    len = byte_size(digits)

    cond do
      decpt <= 0 ->
        "0." <> String.duplicate("0", -decpt) <> digits

      decpt >= len ->
        digits <> String.duplicate("0", decpt - len) <> ".0"

      true ->
        <<int_part::binary-size(^decpt), frac_part::binary>> = digits
        int_part <> "." <> frac_part
    end
  end

  # Decompose a float into {shortest_digits, decpt} such that
  # value = 0.<digits> x 10^decpt. Digits carry no leading or trailing zeros
  # (except the value 0 itself, handled by callers before this is reached for
  # repr; trunc-path handles integrals).
  defp shortest_digits(v) do
    s = :erlang.float_to_binary(v, [:short])
    {mantissa, exp10} = split_exponent(s)
    {int_part, frac_part} = split_dot(mantissa)
    raw = int_part <> frac_part
    digits = raw |> String.trim_leading("0") |> String.trim_trailing("0")
    # 0.D x 10^decpt convention: decpt = exp10 + len(int_part) - leading zeros
    leading_zeros = byte_size(raw) - byte_size(String.trim_leading(raw, "0"))
    decpt = exp10 + byte_size(int_part) - leading_zeros
    {digits, decpt}
  end

  defp split_exponent(s) do
    case :binary.split(s, "e") do
      [m] -> {m, 0}
      [m, e] -> {m, String.to_integer(e)}
    end
  end

  defp split_dot(m) do
    case :binary.split(m, ".") do
      [i] -> {i, ""}
      [i, f] -> {i, f}
    end
  end
end
