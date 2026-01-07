defmodule MishkaCmsCore.Runtime.PageForm.Rules do
  @moduledoc """
  One form's declared rules, executed as a schemaless `Ecto.Changeset`.

  ## What a rule is

  A rule is one of the HTML constraint attributes already on the field node, lifted at compile time
  by `MishkaCmsCore.Runtime.PageBuilder.PageForms` into the field's `:rules` list. There is no second
  place to declare one, so the browser and the server enforce the same sentence:

      :required                 required
      {:min_length, n}          minlength="n"
      {:max_length, n}          maxlength="n"
      {:min, n}                 min="n"
      {:max, n}                 max="n"
      {:pattern, source}        pattern="source"
      {:format, :email}         data-format="email"
      {:format, :url}           data-format="url"
      {:confirms, "password"}   data-confirms="password"

  A rule this module does not know is ignored rather than raised on, because a template compiled by
  a newer editor must still run on an older node.

  `pattern` is read the way HTML reads it: the whole value has to match, not some piece of it, so
  `pattern="[0-9]{5}"` refuses `abcd12345xyz` on both sides of the wire.

  ## The shapes callers depend on

  `changeset/2` answers an `Ecto.Changeset` over `{%{}, types}`, so every error is
  `{message, opts}` — the only shape a kit's `translate_error/1` matches — with Ecto's own
  `opts[:count]` and `opts[:number]` where Gettext's plural rules can read them.

  The changeset keeps the WHOLE params map, including the `_unused_<field>` markers the client
  sends, which is what lets `Phoenix.Component.used_input?/1` work over a form built from it.

  `apply_changes/2` answers a plain map of the cast values, keyed by atom, for whoever receives the
  submission.

  ## Nothing here raises on what a visitor typed

  A visitor can post a list where a string is expected, a word where a number is expected, or a date
  that is not one. Each of those is a validation error and never an exception, so a keystroke can
  never take a published page down. Where a stock Ecto validator would raise on such a value —
  `validate_number/3` on a word, `validate_format/4` on an integer — the value is read first and the
  validator is only reached with what it accepts.

  See `MishkaCmsCore.Runtime.PageForm` for the runtime that builds the form and handles the events.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  import Ecto.Changeset

  @email ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @url ~r{^https?://\S+$}

  @number_messages %{
    greater_than_or_equal_to:
      dgettext_noop("errors", "must be greater than or equal to %{number}"),
    less_than_or_equal_to: dgettext_noop("errors", "must be less than or equal to %{number}")
  }

  @doc """
  The changeset for one form spec against one params map.

  `values` is the form's OWN scoped params — `params["contact"]`, not the whole event payload. Keys
  the spec does not declare are dropped by `cast/4` rather than reported.
  """
  @spec changeset(map(), map()) :: Ecto.Changeset.t()
  def changeset(spec, values) do
    {%{}, Map.new(spec.fields, &{&1.key, &1.type})}
    |> cast(values, Enum.map(spec.fields, & &1.key))
    |> then(&Enum.reduce(spec.fields, &1, fn field, acc -> apply_rules(acc, field) end))
  end

  @doc "The cast values of one submission, as a map keyed by the fields the form declares."
  @spec apply_changes(map(), map()) :: map()
  def apply_changes(spec, values), do: spec |> changeset(values) |> Ecto.Changeset.apply_changes()

  defp apply_rules(changeset, field),
    do: Enum.reduce(field.rules, changeset, &rule(&2, field.key, &1))

  defp rule(changeset, key, :required), do: validate_required(changeset, [key])

  defp rule(changeset, key, {:min_length, n}),
    do: on_string(changeset, key, &validate_length(&1, key, min: n))

  defp rule(changeset, key, {:max_length, n}),
    do: on_string(changeset, key, &validate_length(&1, key, max: n))

  defp rule(changeset, key, {:min, n}), do: bound(changeset, key, :greater_than_or_equal_to, n)
  defp rule(changeset, key, {:max, n}), do: bound(changeset, key, :less_than_or_equal_to, n)

  defp rule(changeset, key, {:format, :email}),
    do:
      on_string(
        changeset,
        key,
        &validate_format(&1, key, @email,
          message: dgettext_noop("errors", "must have the @ sign and no spaces")
        )
      )

  defp rule(changeset, key, {:format, :url}),
    do:
      on_string(
        changeset,
        key,
        &validate_format(&1, key, @url, message: dgettext_noop("errors", "must start with http"))
      )

  defp rule(changeset, key, {:pattern, source}), do: pattern(changeset, key, compiled(source))

  defp rule(changeset, key, {:confirms, other}),
    do: confirms(changeset, key, declared_key(changeset, other))

  defp rule(changeset, _key, _unknown), do: changeset

  defp pattern(changeset, _key, nil), do: changeset

  defp pattern(changeset, key, regex),
    do: on_string(changeset, key, &validate_format(&1, key, regex))

  defp confirms(changeset, _key, nil), do: changeset

  defp confirms(changeset, key, other) do
    expected = get_field(changeset, other)

    validate_change(changeset, key, {:confirmation, other}, fn ^key, value ->
      matched(value == expected, key)
    end)
  end

  defp matched(true, _key), do: []

  defp matched(false, key),
    do: [
      {key, {dgettext_noop("errors", "does not match confirmation"), [validation: :confirmation]}}
    ]

  # `data-confirms` names its partner as text an author typed, so it is matched against the keys the
  # form already declares instead of being turned into an atom. A name for a field this form does
  # not have is no rule at all.
  defp declared_key(changeset, name) do
    changeset.types |> Map.keys() |> Enum.find(&(Atom.to_string(&1) == name))
  end

  # `validate_length/3` has no clause for a number or a date and `validate_format/4` raises on one,
  # so `minlength` or `pattern` on a field that also carries `data-cast="integer"` would end the
  # visitor's request. A rule about text is applied to text and to nothing else.
  defp on_string(changeset, key, validation),
    do: changeset |> get_change(key) |> run(changeset, validation)

  defp run(value, changeset, validation) when is_binary(value), do: validation.(changeset)
  defp run(_other, changeset, _validation), do: changeset

  # `validate_number/3` raises on anything that is not already a number, and a field carrying `min`
  # casts to a string unless its author also set `data-cast`, which would make the raise the common
  # case. The messages and the option keys are Ecto's so a translation written for one is read by
  # the other.
  defp bound(changeset, key, kind, target) do
    validate_change(changeset, key, {:number, [{kind, target}]}, fn ^key, value ->
      value |> number() |> outside(key, kind, target)
    end)
  end

  defp outside(:error, key, _kind, _target),
    do: [{key, {dgettext_noop("errors", "is invalid"), [validation: :number]}}]

  defp outside({:ok, actual}, _key, :greater_than_or_equal_to, target) when actual >= target,
    do: []

  defp outside({:ok, actual}, _key, :less_than_or_equal_to, target) when actual <= target, do: []

  defp outside({:ok, _actual}, key, kind, target),
    do: [{key, {@number_messages[kind], [validation: :number, kind: kind, number: target]}}]

  defp number(value) when is_number(value), do: {:ok, value}

  defp number(value) when is_binary(value),
    do: value |> String.trim() |> Float.parse() |> parsed()

  defp number(_other), do: :error

  defp parsed({number, ""}), do: {:ok, number}
  defp parsed(_other), do: :error

  # A pattern is authored once and matched on every keystroke, so each distinct source is compiled
  # once and kept — anchored, because the browser anchors it. A source that will not compile is
  # remembered as `nil` and contributes no rule, rather than raising from inside a form the author
  # already saved.
  defp compiled(source) do
    key = {__MODULE__, :anchored, source}

    case :persistent_term.get(key, :absent) do
      :absent -> memoise(key, source |> anchored() |> Regex.compile())
      regex -> regex
    end
  end

  # HTML's `pattern` matches the WHOLE value: the browser tests the entirety of what was typed, so
  # `pattern="[0-9]{5}"` refuses `abcd12345xyz` there. `Regex.match?/2` is a substring test, which
  # made the server strictly weaker than the client on every pattern an author writes — and the
  # server is the only gate a crafted payload or the `phx-change` path ever meets. `\A` and `\z`
  # rather than `^` and `$` because `$` in PCRE also matches before a final newline, and the group
  # because `cat|dog` anchored without one is `\Acat` or `dog\z`, which accepts `hotdog`.
  defp anchored(source), do: "\\A(?:" <> source <> ")\\z"

  defp memoise(key, {:ok, regex}) do
    :persistent_term.put(key, regex)
    regex
  end

  defp memoise(key, {:error, _uncompilable}) do
    :persistent_term.put(key, nil)
    nil
  end
end
