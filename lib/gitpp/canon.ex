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
  # The §3 ENCODING boundary. Distinct from @json_safe_integer above, which
  # decides whether an integer survives a float64 round trip. 2**53-1 is the
  # right constant for decoding and the wrong one for encoding: the spec's
  # integer band ends at 1e16, which is ~9.9e14 higher. Reusing one for both
  # sent every value in [2**53, 1e16) down the integer path.
  @spec_integer_band 1.0e16

  # ------------------------------------------------------------------ ingest

  @doc """
  Float64-canonicalise a JSON value recursively: integers with
  |n| > 2^53-1 become the nearest IEEE-754 double. Everything else is
  structurally preserved.
  """
  def float64_canonicalise(v) when is_integer(v) do
    if abs(v) > @json_safe_integer, do: v * 1.0, else: v
  end

  def float64_canonicalise(v) when is_map(v) do
    Map.new(v, fn {k, val} -> {k, float64_canonicalise(val)} end)
  end

  def float64_canonicalise(v) when is_list(v), do: Enum.map(v, &float64_canonicalise/1)
  def float64_canonicalise(v), do: v

  # ------------------------------------------------------------- value class

  @doc """
  A canonical key for a JSON value under CPython equality semantics, used for
  conflict distinctness: True == 1 == 1.0 and False == 0 == 0.0 collapse into
  one numeric class; strings, null, lists and dicts are their own classes
  (recursively). Assumes the value is already float64-canonicalised.
  """
  def value_key(v) when is_boolean(v), do: {:num, if(v, do: 1.0, else: 0.0)}
  def value_key(v) when is_integer(v), do: {:num, v * 1.0}
  def value_key(v) when is_float(v), do: {:num, v}
  def value_key(nil), do: :null
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
  def encode(v) when is_integer(v) do
    # is_integer/1 is true for bignums, so this clause wins over is_float/1
    # and leaf_number/1 never runs. In [1e16, 1e21) the value is still an
    # integer here but §3 requires scientific, so route it through the same
    # rule rather than printing exact digits.
    if abs(v) >= @spec_integer_band, do: leaf_number(v * 1.0), else: Integer.to_string(v)
  end
  def encode(v) when is_float(v), do: leaf_number(v)

  def encode!(v), do: v |> encode() |> IO.iodata_to_binary()

  # Python json string escaping with ensure_ascii=True: ", \, the short
  # escapes, and every code point outside 0x20..0x7E as \uXXXX (surrogate
  # pairs for non-BMP).
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
          cp when cp < 0x20 or cp > 0x7E -> unicode_escape(cp)
          cp -> <<cp::utf8>>
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
      v == trunc(v) and abs(v) < @spec_integer_band -> Integer.to_string(trunc(v))
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

    if exp < -4 or exp >= 17 do
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
