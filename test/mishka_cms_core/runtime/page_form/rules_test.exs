defmodule MishkaCmsCore.Runtime.PageForm.RulesTest do
  @moduledoc """
  The rules a page form validates by, one per HTML constraint attribute its author set on the field.

  Two properties matter more than any single rule. The first is the error SHAPE: every failure has
  to come out as `{message, opts}`, because that is the only thing a kit's `translate_error/1`
  matches on, and a bare string reaches the visitor as a crash in the middle of a render. The second
  is that nothing a visitor can type raises. A word in a number box, a list where a string was
  declared, a nested map, a pattern the author saved before it compiled — each is a validation error
  and never an exception, so a published page cannot be taken down by a keystroke.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageForm.Rules

  defp field(key, rules, type \\ :string), do: %{key: key, type: type, rules: rules}

  defp spec(fields), do: %{fields: fields}

  defp errors(fields, values), do: fields |> spec() |> Rules.changeset(values) |> Map.get(:errors)

  defp error(fields, values, key), do: fields |> errors(values) |> Keyword.get(key)

  defp valid?(fields, values), do: fields |> spec() |> Rules.changeset(values) |> Map.get(:valid?)

  defp shaped?(errors) do
    Enum.all?(errors, fn
      {key, {message, opts}} -> is_atom(key) and is_binary(message) and Keyword.keyword?(opts)
      _other -> false
    end)
  end

  describe "required" do
    test "a blank value is reported as blank" do
      assert error([field(:name, [:required])], %{"name" => ""}, :name) ==
               {"can't be blank", [validation: :required]}
    end

    test "a missing key is reported as blank" do
      assert error([field(:name, [:required])], %{}, :name) ==
               {"can't be blank", [validation: :required]}
    end

    test "whitespace only is blank, because Ecto trims before it decides" do
      assert error([field(:name, [:required])], %{"name" => "   "}, :name) ==
               {"can't be blank", [validation: :required]}
    end

    test "a filled value passes" do
      assert valid?([field(:name, [:required])], %{"name" => "Shahryar"})
      assert errors([field(:name, [:required])], %{"name" => "Shahryar"}) == []
    end
  end

  describe "minlength and maxlength" do
    test "a value under minlength carries the count Gettext pluralises on" do
      {message, opts} = error([field(:name, [{:min_length, 2}])], %{"name" => "a"}, :name)

      assert message == "should be at least %{count} character(s)"
      assert opts[:count] == 2
      assert opts[:validation] == :length
      assert opts[:kind] == :min
    end

    test "a value at minlength passes" do
      assert valid?([field(:name, [{:min_length, 2}])], %{"name" => "ab"})
    end

    test "a value over maxlength carries the count" do
      {message, opts} = error([field(:name, [{:max_length, 3}])], %{"name" => "abcd"}, :name)

      assert message == "should be at most %{count} character(s)"
      assert opts[:count] == 3
      assert opts[:kind] == :max
    end

    test "a value at maxlength passes" do
      assert valid?([field(:name, [{:max_length, 3}])], %{"name" => "abc"})
    end

    test "a length rule on a field cast to a number is skipped instead of raising" do
      fields = [field(:age, [{:min_length, 2}], :integer)]

      assert valid?(fields, %{"age" => "7"})
    end
  end

  describe "min and max" do
    test "a value under min is reported with Ecto's message and number" do
      assert error([field(:age, [{:min, 18}])], %{"age" => "17"}, :age) ==
               {"must be greater than or equal to %{number}",
                [validation: :number, kind: :greater_than_or_equal_to, number: 18]}
    end

    test "a value at min passes" do
      assert valid?([field(:age, [{:min, 18}])], %{"age" => "18"})
    end

    test "a value over max is reported" do
      assert error([field(:age, [{:max, 65}])], %{"age" => "66"}, :age) ==
               {"must be less than or equal to %{number}",
                [validation: :number, kind: :less_than_or_equal_to, number: 65]}
    end

    test "a value at max passes" do
      assert valid?([field(:age, [{:max, 65}])], %{"age" => "65"})
    end

    test "a word where a number is expected is invalid, not a raise" do
      assert error([field(:age, [{:min, 18}])], %{"age" => "abc"}, :age) ==
               {"is invalid", [validation: :number]}
    end

    test "a half-numeric value is invalid rather than parsed to its prefix" do
      assert error([field(:age, [{:min, 18}])], %{"age" => "20 years"}, :age) ==
               {"is invalid", [validation: :number]}
    end

    test "a decimal string compares against a whole-number bound" do
      assert valid?([field(:score, [{:min, 1}, {:max, 5}])], %{"score" => "4.5"})
      refute valid?([field(:score, [{:min, 1}, {:max, 5}])], %{"score" => "5.5"})
    end

    test "an already-cast number compares without going through text" do
      fields = [field(:age, [{:min, 18}], :integer)]

      assert valid?(fields, %{"age" => "21"})
      refute valid?(fields, %{"age" => "12"})
    end

    test "a number rule on a value the cast rejected reports the cast, not the bound" do
      fields = [field(:age, [{:min, 18}], :integer)]

      assert error(fields, %{"age" => "abc"}, :age) ==
               {"is invalid", [type: :integer, validation: :cast]}
    end

    test "both bounds on one field report only the one that failed" do
      fields = [field(:age, [{:min, 18}, {:max, 65}])]

      assert [age: {_message, opts}] = errors(fields, %{"age" => "70"})
      assert opts[:kind] == :less_than_or_equal_to
    end
  end

  describe "data-format" do
    test "an address with no at sign fails" do
      assert error([field(:email, [{:format, :email}])], %{"email" => "nope"}, :email) ==
               {"must have the @ sign and no spaces", [validation: :format]}
    end

    test "an address with a space fails" do
      refute valid?([field(:email, [{:format, :email}])], %{"email" => "a b@c.co"})
    end

    test "a real address passes" do
      assert valid?([field(:email, [{:format, :email}])], %{"email" => "a@b.co"})
    end

    test "a url without a scheme fails and one with it passes" do
      fields = [field(:site, [{:format, :url}])]

      assert error(fields, %{"site" => "mishka.tools"}, :site) ==
               {"must start with http", [validation: :format]}

      assert valid?(fields, %{"site" => "https://mishka.tools"})
    end

    test "a format rule on a field cast to a number is skipped instead of raising" do
      assert valid?([field(:age, [{:format, :email}], :integer)], %{"age" => "7"})
    end
  end

  describe "pattern" do
    test "a value the pattern does not match fails" do
      assert error([field(:code, [{:pattern, "^[0-9]{5}$"}])], %{"code" => "12"}, :code) ==
               {"has invalid format", [validation: :format]}
    end

    test "a value the pattern matches passes" do
      assert valid?([field(:code, [{:pattern, "^[0-9]{5}$"}])], %{"code" => "12345"})
    end

    test "a pattern that will not compile contributes no rule at all" do
      fields = [field(:code, [{:pattern, "["}])]

      assert valid?(fields, %{"code" => "anything at all"})
      assert errors(fields, %{"code" => "anything at all"}) == []
    end

    test "an uncompilable pattern stays harmless on the second run, when it is memoised" do
      fields = [field(:code, [{:pattern, "(unclosed"}])]

      assert valid?(fields, %{"code" => "x"})
      assert valid?(fields, %{"code" => "y"})
    end

    test "a compiled pattern keeps working on the second run" do
      fields = [field(:code, [{:pattern, "^ab+c$"}])]

      assert valid?(fields, %{"code" => "abbc"})
      refute valid?(fields, %{"code" => "ac"})
    end

    test "the whole value has to match, the way the browser reads the same attribute" do
      fields = [field(:zip, [{:pattern, "[0-9]{5}"}])]

      assert valid?(fields, %{"zip" => "12345"})
      refute valid?(fields, %{"zip" => "abcd12345xyz"})
      refute valid?(fields, %{"zip" => "12345 "})
    end

    test "a trailing newline is not the end of the value" do
      refute valid?([field(:zip, [{:pattern, "[0-9]{5}"}])], %{"zip" => "12345\n"})
    end

    test "an alternation is anchored as a whole, not one branch at a time" do
      fields = [field(:pet, [{:pattern, "cat|dog"}])]

      assert valid?(fields, %{"pet" => "dog"})
      refute valid?(fields, %{"pet" => "hotdog"})
    end

    test "a pattern the author anchored themselves still means what it says" do
      fields = [field(:code, [{:pattern, "^[0-9]{5}$"}])]

      assert valid?(fields, %{"code" => "12345"})
      refute valid?(fields, %{"code" => "x12345"})
    end
  end

  describe "data-confirms" do
    test "a mismatch is reported on the confirming field" do
      fields = [field(:password, []), field(:password_confirmation, [{:confirms, "password"}])]

      assert error(
               fields,
               %{"password" => "abc", "password_confirmation" => "abd"},
               :password_confirmation
             ) == {"does not match confirmation", [validation: :confirmation]}
    end

    test "a match passes" do
      fields = [field(:password, []), field(:password_confirmation, [{:confirms, "password"}])]

      assert valid?(fields, %{"password" => "abc", "password_confirmation" => "abc"})
    end

    test "confirming a field the form does not declare is no rule" do
      fields = [field(:password_confirmation, [{:confirms, "nowhere"}])]

      assert valid?(fields, %{"password_confirmation" => "abc"})
    end

    test "an untouched confirmation field is not compared" do
      fields = [field(:password, []), field(:password_confirmation, [{:confirms, "password"}])]

      assert valid?(fields, %{"password" => "abc"})
    end
  end

  describe "values a visitor can post that are not text" do
    test "a list where a string was declared is a cast error, not a raise" do
      assert error([field(:tags, [:required])], %{"tags" => ["a", "b"]}, :tags) ==
               {"is invalid", [type: :string, validation: :cast]}
    end

    test "a nested map where a string was declared is a cast error, not a raise" do
      assert error([field(:name, [:required])], %{"name" => %{"a" => "b"}}, :name) ==
               {"is invalid", [type: :string, validation: :cast]}
    end

    test "a list against every rule at once still only reports the cast" do
      fields = [
        field(:name, [
          :required,
          {:min_length, 2},
          {:max_length, 5},
          {:min, 1},
          {:max, 9},
          {:pattern, "^a$"},
          {:format, :email}
        ])
      ]

      assert errors(fields, %{"name" => ["a", "b"]}) ==
               [name: {"is invalid", [type: :string, validation: :cast]}]
    end
  end

  describe "what the changeset ignores" do
    test "a field with no rules accepts anything" do
      assert valid?([field(:note, [])], %{"note" => "whatever, at any length, with $ymbols"})
      assert valid?([field(:note, [])], %{})
    end

    test "params the form does not declare are dropped rather than reported" do
      changeset =
        Rules.changeset(spec([field(:name, [:required])]), %{
          "name" => "Shahryar",
          "surprise" => "x",
          "_unused_name" => ""
        })

      assert changeset.valid?
      assert changeset.changes == %{name: "Shahryar"}
    end

    test "the whole params map survives on the changeset, so used_input? can read it" do
      changeset =
        Rules.changeset(spec([field(:name, [])]), %{"name" => "a", "_unused_email" => ""})

      assert changeset.params == %{"name" => "a", "_unused_email" => ""}
    end

    test "a rule this version does not know is ignored" do
      assert valid?([field(:name, [{:sometime_later, 3}, :from_a_newer_editor])], %{"name" => "a"})
    end
  end

  describe "the error shape every kit matches on" do
    test "each failure is a binary message and a keyword list" do
      fields = [
        field(:name, [:required]),
        field(:nick, [{:min_length, 4}]),
        field(:bio, [{:max_length, 2}]),
        field(:age, [{:min, 18}]),
        field(:rank, [{:max, 3}]),
        field(:word, [{:min, 1}]),
        field(:code, [{:pattern, "^z$"}]),
        field(:email, [{:format, :email}]),
        field(:site, [{:format, :url}]),
        field(:tags, []),
        field(:password, []),
        field(:password_confirmation, [{:confirms, "password"}])
      ]

      values = %{
        "name" => "",
        "nick" => "abc",
        "bio" => "abcd",
        "age" => "1",
        "rank" => "9",
        "word" => "abc",
        "code" => "q",
        "email" => "nope",
        "site" => "nope",
        "tags" => ["a"],
        "password" => "abc",
        "password_confirmation" => "abd"
      }

      found = errors(fields, values)

      assert shaped?(found)

      assert found |> Keyword.keys() |> Enum.sort() ==
               ~w(age bio code email name nick password_confirmation rank site tags word)a
    end
  end

  describe "apply_changes/2" do
    test "answers the cast values keyed by the fields the form declares" do
      fields = [
        field(:name, [:required]),
        field(:age, [], :integer),
        field(:agreed, [], :boolean)
      ]

      assert Rules.apply_changes(spec(fields), %{
               "name" => "Shahryar",
               "age" => "37",
               "agreed" => "true",
               "surprise" => "dropped"
             }) == %{name: "Shahryar", age: 37, agreed: true}
    end

    test "leaves out what the visitor did not fill in" do
      fields = [field(:name, []), field(:note, [])]

      assert Rules.apply_changes(spec(fields), %{"name" => "Shahryar"}) == %{name: "Shahryar"}
    end

    test "leaves out what failed to cast rather than raising" do
      fields = [field(:name, []), field(:age, [], :integer)]

      assert Rules.apply_changes(spec(fields), %{"name" => "Shahryar", "age" => "abc"}) ==
               %{name: "Shahryar"}
    end
  end
end
