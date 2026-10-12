defmodule MishkaCmsCore.GettextTemplatesTest do
  @moduledoc """
  The core's `.pot` files hold MishkaGervaz's and the extensions' own words too.

  A host sets `config :mishka_gervaz, :gettext_backend, MishkaCmsCore.Gettext`, so an error flash's
  "%{action} failed: %{reason}" or a table's "No records found" is translated from the core's `.po`
  files. A translator works from the core's `.pot` files, so each of MishkaGervaz's messages has to
  be in the core's template of the same domain. `mix mishka_cms_core.gettext.gervaz` puts them
  there, and `mix mishka_cms_core.gettext.extensions` puts the extensions' there, each with its
  references outside the core, which `mix gettext.extract` has to keep.
  """
  use ExUnit.Case, async: true

  @core Path.expand("../../priv/gettext", __DIR__)

  test "every message of MishkaGervaz's templates is in the core's template of its domain" do
    templates = Path.wildcard(Application.app_dir(:mishka_gervaz, "priv/gettext/*.pot"))

    assert Enum.map(templates, &Path.basename/1) |> Enum.sort() ==
             ["errors.pot", "mishka_gervaz.pot"]

    missing =
      for template <- templates,
          core = Path.join(@core, Path.basename(template)),
          key <- keys(template) -- keys(core),
          do: "#{Path.basename(template)}: #{inspect(key)}"

    assert missing == [],
           "run mix mishka_cms_core.gettext.gervaz; missing from the core:\n" <>
             Enum.join(missing, "\n")
  end

  test "mix gettext.extract keeps every message referenced only outside the core" do
    pattern = Mix.Project.config()[:gettext][:excluded_refs_from_purging]

    purged =
      for template <- Path.wildcard(Path.join(@core, "*.pot")),
          message <- Expo.PO.parse_file!(template).messages,
          files = Enum.map(List.flatten(message.references), &elem(&1, 0)),
          files != [] and Enum.all?(files, &String.starts_with?(&1, "../")),
          not Enum.any?(files, &Regex.match?(pattern, &1)),
          do: "#{Path.basename(template)}: #{inspect(Expo.Message.key(message))}"

    assert purged == [],
           "the :excluded_refs_from_purging of mix.exs does not keep:\n" <>
             Enum.join(purged, "\n")
  end

  defp keys(path) do
    if File.exists?(path) do
      path
      |> Expo.PO.parse_file!()
      |> Map.fetch!(:messages)
      |> Enum.map(&Expo.Message.key/1)
    else
      []
    end
  end
end
