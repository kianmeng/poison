defmodule Poison.MissingDependencyError do
  @type t :: %__MODULE__{name: String.t()}

  defexception name: nil

  def message(%{name: name}) do
    "missing optional dependency: #{name}"
  end
end

defmodule Poison.ParseError do
  alias Poison.Parser

  @type t :: %__MODULE__{data: String.t(), skip: non_neg_integer, value: Parser.t()}

  alias Code.Identifier

  defexception data: "", skip: 0, value: nil

  def message(%{data: data, skip: skip, value: value}) when not is_nil(value) do
    <<head::binary-size(skip), _rest::bits>> = data
    pos = String.length(head)
    "cannot parse value at position #{pos}: #{inspect(value)}"
  end

  def message(%{data: data, skip: skip}) when is_bitstring(data) do
    <<head::binary-size(skip), rest::bits>> = data
    pos = String.length(head)

    case rest do
      <<>> ->
        "unexpected end of input at position #{pos}"

      <<token::utf8, _::bits>> ->
        "unexpected token at position #{pos}: #{escape(token)}"

      _other ->
        "cannot parse value at position #{pos}: #{inspect(rest)}"
    end
  end

  def message(%{data: data}) do
    "unsupported value: #{inspect(data)}"
  end

  defp escape(token) do
    {value, _} = Identifier.escape(<<token::utf8>>, ?\\)
    value
  end
end

defmodule Poison.Parser do
  @moduledoc """
  An RFC 7159 and ECMA 404 conforming JSON parser.

  See: https://tools.ietf.org/html/rfc7159
  See: http://www.ecma-international.org/publications/files/ECMA-ST/ECMA-404.pdf
  """

  @compile :inline
  @compile :inline_list_funcs
  @compile {:inline_size, 100}
  @compile {:inline_effort, 300}
  @compile {:inline_unroll, 2}

  if Application.get_env(:poison, :native) do
    @compile [:native, {:hipe, [:o3]}]
  end

  use Bitwise

  alias Poison.{Decoder, ParseError}

  @typep value :: nil | true | false | map | list | float | integer | String.t()

  if Code.ensure_loaded?(Decimal) do
    @type t :: value | Decimal.t()
  else
    @type t :: value
  end

  defmacrop stacktrace do
    if Version.compare(System.version(), "1.7.0") != :lt do
      quote do: __STACKTRACE__
    else
      quote do: System.stacktrace()
    end
  end

  defmacrop syntax_error(skip) do
    quote do
      raise ParseError, skip: unquote(skip)
    end
  end

  @spec parse!(iodata | binary, Decoder.options()) :: t | no_return
  def parse!(value, options \\ %{})

  def parse!(iodata, options) when not is_binary(iodata) do
    iodata |> IO.iodata_to_binary() |> parse!(options)
  end

  def parse!(data, options) do
    {value, skip} = value(data, data, 0, Map.get(options, :keys), Map.get(options, :decimal))
    <<_::binary-size(skip), rest::bits>> = data
    skip_whitespace(rest, skip, value)
  rescue
    exception in [ParseError] ->
      reraise ParseError, [data: data, skip: exception.skip, value: exception.value], stacktrace()
  end

  @compile {:inline, value: 5}

  for char <- '\s\t\n\r' do
    defp value(<<unquote(char), rest::bits>>, data, skip, keys, decimal) do
      value(rest, data, skip + 1, keys, decimal)
    end
  end

  defp value(<<"false", _rest::bits>>, _data, skip, _keys, _decimal) do
    {false, skip + 5}
  end

  defp value(<<"true", _rest::bits>>, _data, skip, _keys, _decimal) do
    {true, skip + 4}
  end

  defp value(<<"null", _rest::bits>>, _data, skip, _keys, _decimal) do
    {nil, skip + 4}
  end

  defp value(<<"-0", rest::bits>>, _data, skip, _keys, decimal) do
    number_frac(rest, skip + 2, decimal, -1, 0, 0)
  end

  defp value(<<?-, rest::bits>>, _data, skip, _keys, decimal) do
    number_int(rest, skip + 1, decimal, -1, 0, 0)
  end

  defp value(<<?0, rest::bits>>, _data, skip, _keys, decimal) do
    number_frac(rest, skip + 1, decimal, 1, 0, 0)
  end

  for digit <- ?1..?9 do
    coef = digit - ?0

    defp value(<<unquote(digit), rest::bits>>, _data, skip, _keys, decimal) do
      number_int(rest, skip + 1, decimal, 1, unquote(coef), 0)
    end
  end

  defp value(<<?", rest::bits>>, data, skip, _keys, _decimal) do
    string_continue(rest, data, skip + 1)
  end

  defp value(<<?[, rest::bits>>, data, skip, keys, decimal) do
    array_values(rest, data, skip + 1, keys, decimal, [])
  end

  defp value(<<?{, rest::bits>>, data, skip, keys, decimal) do
    object_pairs(rest, data, skip + 1, keys, decimal, [])
  end

  defp value(_rest, _data, skip, _keys, _decimal) do
    syntax_error(skip)
  end

  ## Objects

  @compile {:inline, object_pairs: 6}

  for char <- '\s\t\n\r' do
    defp object_pairs(<<unquote(char), rest::bits>>, data, skip, keys, decimal, acc) do
      object_pairs(rest, data, skip + 1, keys, decimal, acc)
    end
  end

  defp object_pairs(<<?}, _rest::bits>>, _data, skip, _keys, _decimal, []) do
    {%{}, skip + 1}
  end

  defp object_pairs(<<?", rest::bits>>, data, skip, keys, decimal, acc) do
    start = skip + 1
    {name, skip} = string_continue(rest, data, start)

    <<_::binary-size(skip), rest::bits>> = data

    {value, skip} = object_value(rest, data, skip, keys, decimal)

    <<_::binary-size(skip), rest::bits>> = data

    object_pairs_continue(rest, data, skip, keys, decimal, [{object_name(name, start, keys), value} | acc])
  end

  defp object_pairs(_rest, _data, skip, _keys, _decimal, _acc) do
    syntax_error(skip)
  end

  @compile {:inline, object_pairs_continue: 6}

  for char <- '\s\t\n\r' do
    defp object_pairs_continue(<<unquote(char), rest::bits>>, data, skip, keys, decimal, acc) do
      object_pairs_continue(rest, data, skip + 1, keys, decimal, acc)
    end
  end

  defp object_pairs_continue(<<?,, rest::bits>>, data, skip, keys, decimal, acc) do
    object_pairs(rest, data, skip + 1, keys, decimal, acc)
  end

  defp object_pairs_continue(<<?}, _rest::bits>>, _data, skip, _keys, _decimal, acc) do
    {:maps.from_list(acc), skip + 1}
  end

  defp object_pairs_continue(_rest, _data, skip, _keys, _decimal, _acc) do
    syntax_error(skip)
  end

  @compile {:inline, object_value: 5}

  for char <- '\s\t\n\r' do
    defp object_value(<<unquote(char), rest::bits>>, data, skip, keys, decimal) do
      object_value(rest, data, skip + 1, keys, decimal)
    end
  end

  defp object_value(<<?:, rest::bits>>, data, skip, keys, decimal) do
    value(rest, data, skip + 1, keys, decimal)
  end

  defp object_value(_rest, _data, skip, _keys, _decimal) do
    syntax_error(skip)
  end

  @compile {:inline, object_name: 3}

  defp object_name(name, skip, :atoms!) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      reraise ParseError, [skip: skip, value: name], stacktrace()
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp object_name(name, _skip, :atoms), do: String.to_atom(name)
  defp object_name(name, _skip, _keys), do: name

  ## Arrays

  @compile {:inline, array_values: 6}

  for char <- '\s\t\n\r' do
    defp array_values(<<unquote(char), rest::bits>>, data, skip, keys, decimal, acc) do
      array_values(rest, data, skip + 1, keys, decimal, acc)
    end
  end

  defp array_values(<<?], _rest::bits>>, _data, skip, _keys, _decimal, _acc) do
    {[], skip + 1}
  end

  defp array_values(rest, data, skip, keys, decimal, acc) do
    {value, skip} = value(rest, data, skip, keys, decimal)

    <<_::binary-size(skip), rest::bits>> = data

    array_values_continue(rest, data, skip, keys, decimal, [value | acc])
  end

  @compile {:inline, array_values_continue: 6}

  for char <- '\s\t\n\r' do
    defp array_values_continue(<<unquote(char), rest::bits>>, data, skip, keys, decimal, acc) do
      array_values_continue(rest, data, skip + 1, keys, decimal, acc)
    end
  end

  defp array_values_continue(<<?,, rest::bits>>, data, skip, keys, decimal, acc) do
    {value, skip} = value(rest, data, skip + 1, keys, decimal)

    <<_::binary-size(skip), rest::bits>> = data

    array_values_continue(rest, data, skip, keys, decimal, [value | acc])
  end

  defp array_values_continue(<<?], _rest::bits>>, _data, skip, _keys, _decimal, acc) do
    {:lists.reverse(acc), skip + 1}
  end

  defp array_values_continue(_rest, _data, skip, _keys, _decimal, _acc) do
    syntax_error(skip)
  end

  ## Numbers

  @compile {:inline, number_int: 6}

  for char <- '0123456789' do
    defp number_int(<<unquote(char), rest::bits>>, skip, decimal, sign, coef, exp) do
      number_int(rest, skip + 1, decimal, sign, coef * 10 + unquote(char - ?0), exp)
    end
  end

  defp number_int(_rest, skip, _decimal, -1, 0, _exp) do
    syntax_error(skip)
  end

  defp number_int(rest, skip, decimal, sign, coef, exp) do
    number_frac(rest, skip, decimal, sign, coef, exp)
  end

  @compile {:inline, number_frac: 6}

  defp number_frac(<<?., rest::bits>>, skip, decimal, sign, coef, exp) do
    number_frac_continue(rest, skip + 1, decimal, sign, coef, exp)
  end

  defp number_frac(rest, skip, decimal, sign, coef, exp) do
    number_exp(rest, skip, decimal, sign, coef, exp)
  end

  @compile {:inline, number_frac_continue: 6}

  for char <- '0123456789' do
    defp number_frac_continue(<<unquote(char), rest::bits>>, skip, decimal, sign, coef, exp) do
      number_frac_continue(rest, skip + 1, decimal, sign, coef * 10 + unquote(char - ?0), exp - 1)
    end
  end

  defp number_frac_continue(_rest, skip, _decimal, _sign, _coef, 0) do
    syntax_error(skip)
  end

  defp number_frac_continue(rest, skip, decimal, sign, coef, exp) do
    number_exp(rest, skip, decimal, sign, coef, exp)
  end

  @compile {:inline, number_exp: 6}

  defp number_exp(<<e, rest::bits>>, skip, decimal, sign, coef, exp) when e in 'eE' do
    {value, skip} = number_exp_continue(rest, skip + 1)
    number_complete(decimal, sign, coef, exp + value, skip)
  end

  defp number_exp(_rest, skip, decimal, sign, coef, exp) do
    number_complete(decimal, sign, coef, exp, skip)
  end

  @compile {:inline, number_exp_continue: 2}

  defp number_exp_continue(<<?-, rest::bits>>, skip) do
    {exp, skip} = number_exp_digits(rest, skip + 1)
    {-exp, skip}
  end

  defp number_exp_continue(<<?+, rest::bits>>, skip) do
    number_exp_digits(rest, skip + 1)
  end

  defp number_exp_continue(rest, skip) do
    number_exp_digits(rest, skip)
  end

  @compile {:inline, number_exp_digits: 2}

  defp number_exp_digits(<<rest::bits>>, skip) do
    case number_digits(rest, skip, 0) do
      {_exp, ^skip} ->
        syntax_error(skip)

      {exp, skip} ->
        {exp, skip}
    end
  end

  defp number_exp_digits(<<>>, skip), do: syntax_error(skip)

  @compile {:inline, number_digits: 3}

  for char <- '0123456789' do
    defp number_digits(<<unquote(char), rest::bits>>, skip, acc) do
      number_digits(rest, skip + 1, acc * 10 + unquote(char - ?0))
    end
  end

  defp number_digits(_rest, skip, acc) do
    {acc, skip}
  end

  @compile {:inline, number_complete: 5}

  if Code.ensure_loaded?(Decimal) do
    defp number_complete(true, sign, coef, exp, skip) do
      {%Decimal{sign: sign, coef: coef, exp: exp}, skip}
    end
  else
    defp number_complete(true, _sign, _coef, _exp, _skip) do
      raise Poison.MissingDependencyError, name: "Decimal"
    end
  end

  defp number_complete(_decimal, sign, coef, 0, skip) do
    {sign * coef, skip}
  end

  defp number_complete(_decimal, sign, coef, exp, skip) do
    {1.0 * sign * coef * pow10(exp), skip}
  rescue
    ArithmeticError ->
      reraise ParseError, [skip: skip, value: "#{sign * coef}e#{exp}"], stacktrace()
  end

  @compile {:inline, pow10: 1}

  Enum.reduce(0..10, 1, fn n, acc ->
    defp pow10(unquote(n)), do: unquote(acc)
    acc * 10
  end)

  defp pow10(n) when n > 10, do: 10_000_000_000 * pow10(n - 10)

  defp pow10(n), do: 1 / pow10(-n)

  ## Strings

  @compile {:inline, string_continue: 3}

  defp string_continue(<<?", _rest::bits>>, _data, skip) do
    {"", skip + 1}
  end

  defp string_continue(rest, data, skip) do
    string_continue(rest, data, skip, false, 0, [])
  end

  @compile {:inline, string_continue: 6}

  defp string_continue(<<?", _rest::bits>>, _data, skip, _unicode, 0, []) do
    {"", skip + 1}
  end

  defp string_continue(<<?", _rest::bits>>, data, skip, _unicode, len, []) do
    {string_extract(data, skip, len), skip + len + 1}
  end

  defp string_continue(<<?", _rest::bits>>, data, skip, false, len, acc) do
    {IO.iodata_to_binary([acc | string_extract(data, skip, len)]), skip + len + 1}
  end

  defp string_continue(<<?", _rest::bits>>, data, skip, _unicode, len, acc) do
    {:unicode.characters_to_binary([acc | string_extract(data, skip, len)], :utf8), skip + len + 1}
  end

  defp string_continue(<<?\\, rest::bits>>, data, skip, unicode, len, acc) do
    string_escape(rest, data, skip + len + 1, unicode, [acc | string_extract(data, skip, len)])
  end

  defp string_continue(<<char, rest::bits>>, data, skip, unicode, len, acc) when char in 0x20..0x80 do
    string_continue(rest, data, skip, unicode, len + 1, acc)
  end

  defp string_continue(<<codepoint::utf8, rest::bits>>, data, skip, _unicode, len, acc) when codepoint > 0x80 do
    string_continue(rest, data, skip, true, len + byte_size(<<codepoint::utf8>>), acc)
  end

  defp string_continue(_other, _data, skip, _unicode, len, _acc) do
    syntax_error(skip + len)
  end

  @compile {:inline, string_extract: 3}

  defp string_extract(<<data::bits>>, skip, len) do
    <<_::binary-size(skip), part::binary-size(len), _::bits>> = data
    part
  end

  @compile {:inline, string_escape: 5}

  for {seq, char} <- Enum.zip(~C("\ntr/fb), ~c("\\\n\t\r/\f\b)) do
    defp string_escape(<<unquote(seq), rest::bits>>, data, skip, unicode, acc) do
      string_continue(rest, data, skip + 1, unicode, 0, [acc, unquote(char)])
    end
  end

  defp string_escape(
         <<?u, seq1::binary-size(4), rest::bits>>,
         data,
         skip,
         _unicode,
         acc
       ) do
    string_escape_continue(rest, data, skip, acc, seq1)
  end

  defp string_escape(_rest, _data, skip, _unicode, _acc), do: syntax_error(skip)

  # http://www.ietf.org/rfc/rfc2781.txt
  # http://perldoc.perl.org/Encode/Unicode.html#Surrogate-Pairs
  # http://mathiasbynens.be/notes/javascript-encoding#surrogate-pairs
  defguardp is_surrogate(cp) when cp in 0xD800..0xDFFF
  defguardp is_surrogate_pair(hi, lo) when hi in 0xD800..0xDBFF and lo in 0xDC00..0xDFFF

  @compile {:inline, string_escape_continue: 5}

  defp string_escape_continue(<<"\\u", seq2::binary-size(4), rest::bits>>, data, skip, acc, seq1) do
    hi = get_codepoint(seq1, skip)
    lo = get_codepoint(seq2, skip + 6)

    cond do
      is_surrogate_pair(hi, lo) ->
        codepoint = 0x10000 + ((hi &&& 0x03FF) <<< 10) + (lo &&& 0x03FF)
        string_continue(rest, data, skip + 11, true, 0, [acc, codepoint])

      is_surrogate(hi) ->
        raise ParseError, skip: skip, value: "\\u#{seq1}\\u#{seq2}"

      is_surrogate(lo) ->
        raise ParseError, skip: skip + 6, value: "\\u#{seq2}"

      true ->
        string_continue(rest, data, skip + 11, true, 0, [acc, hi, lo])
    end
  end

  defp string_escape_continue(rest, data, skip, acc, seq1) do
    string_continue(rest, data, skip + 5, true, 0, [acc, get_codepoint(seq1, skip)])
  end

  @compile {:inline, get_codepoint: 2}

  defp get_codepoint(seq, skip) do
    String.to_integer(seq, 16)
  rescue
    ArgumentError ->
      reraise ParseError, [skip: skip, value: "\\u#{seq}"], stacktrace()
  end

  ## Whitespace

  @compile {:inline, skip_whitespace: 3}

  defp skip_whitespace(<<>>, _skip, value) do
    value
  end

  for char <- '\s\n\t\r' do
    defp skip_whitespace(<<unquote(char), rest::bits>>, skip, value) do
      skip_whitespace(rest, skip + 1, value)
    end
  end

  defp skip_whitespace(_rest, skip, _value) do
    syntax_error(skip)
  end
end
