# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaCmsCore.Gettext.ExtensionsTest do
  @moduledoc """
  `mix mishka_cms_core.gettext.extensions`, run in an extension, writes what the extension marks
  with `MishkaCmsCore.Gettext` into the core's templates.

  The extension is a fixture project written under `tmp/` beside a directory standing for the core,
  and the task runs in it through `Mix.Project.in_project/3`, so it is compiled in this VM with
  Gettext's extractor on. The extractor is global, so the module is not async.
  """
  use ExUnit.Case, async: false

  alias Mix.MishkaCmsCore.GettextTemplates

  @labels """
  defmodule FixtureExtension.Labels do
    use Gettext, backend: MishkaCmsCore.Gettext

    @statuses [gettext_noop("Draft"), dgettext_noop("mishka_gervaz", "Published")]

    def statuses, do: @statuses

    def greeting(name), do: gettext("Hello %{name}", name: name)

    def posts(count), do: ngettext("One post", "%{count} posts", count)

    def invalid_front_page, do: dgettext("errors", "is not a valid front page")

    def options, do: [label: fn -> dgettext("mishka_gervaz", "Front page") end]
  end
  """

  @card ~S'''
  defmodule FixtureExtension.Card do
    use Phoenix.Component
    use Gettext, backend: MishkaCmsCore.Gettext

    def card(assigns) do
      ~H"""
      <p>{dgettext("mishka_gervaz", "Group")}</p>
      """
    end
  end
  '''

  @mix_exs """
  defmodule FixtureExtension.MixProject do
    use Mix.Project

    def project do
      [
        app: :fixture_extension,
        version: "0.0.1",
        deps: [],
        consolidate_protocols: false,
        prune_code_paths: false
      ]
    end
  end
  """

  @labels_ref "../fixture_extension/lib/fixture_extension/labels.ex"
  @card_ref "../fixture_extension/lib/fixture_extension/card.ex"

  setup_all do
    root = Path.join([File.cwd!(), "tmp", inspect(__MODULE__)])
    File.rm_rf!(root)

    core = Path.join(root, "core")
    extension = Path.join(root, "fixture_extension")

    write_core_templates(core)
    write_extension(extension)

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    [first, second] =
      Mix.Project.in_project(:fixture_extension, extension, fn _project ->
        for _run <- 1..2 do
          Mix.Tasks.MishkaCmsCore.Gettext.Extensions.run(["--core", core])
          templates(core)
        end
      end)

    Mix.shell(shell)

    %{core: core, first: first, second: second}
  end

  test "every mark of the extension is in the core's template of its domain", %{first: first} do
    default = parse(first["default.pot"])
    gervaz = parse(first["mishka_gervaz.pot"])
    errors = parse(first["errors.pot"])

    assert references(default, "Hello %{name}") == [{@labels_ref, 8}]
    assert %Expo.Message.Plural{msgid_plural: ["%{count} posts"]} = find(default, "One post")
    assert references(default, "One post") == [{@labels_ref, 10}]
    assert references(errors, "is not a valid front page") == [{@labels_ref, 12}]
    assert references(gervaz, "Front page") == [{@labels_ref, 14}]
    assert references(gervaz, "Group") == [{@card_ref, 7}]

    for template <- [default, gervaz, errors],
        message <- template.messages,
        Enum.any?(references(message), &match?({"../fixture_extension/" <> _, _}, &1)) do
      assert Expo.Message.has_flag?(message, "elixir-autogen")
    end
  end

  test "a message another project marks too keeps both references", %{first: first} do
    gervaz = parse(first["mishka_gervaz.pot"])
    default = parse(first["default.pot"])

    assert references(gervaz, "Published") == [
             {@labels_ref, 4},
             {"../other_extension/lib/other.ex", 3}
           ]

    assert references(default, "Draft") == [{"lib/mishka_cms_core/core.ex", 1}]
    assert find(gervaz, "Written by hand")
    refute find(gervaz, "No longer marked")
  end

  test "running the task again changes nothing", %{first: first, second: second} do
    assert first == second
  end

  test "mix gettext.extract in the core keeps the extension's messages", %{first: first} do
    config = Mix.Project.config()[:gettext]

    for {_file, content} <- first do
      template = parse(content)
      core = %{template | messages: Enum.filter(template.messages, &core?/1)}
      kept = Gettext.Extractor.merge_template(template, core, config)

      assert keys(kept) == keys(template)
    end
  end

  test "two projects writing one template leave it the same whatever order they run in", %{
    core: core
  } do
    before = templates(core)
    other = Path.join(Path.dirname(core), "other_extension")

    published = %Expo.Message.Singular{
      msgid: ["Published"],
      references: [[{"lib/other.ex", 3}]],
      flags: [["elixir-autogen"]],
      comments: ["# Statuses"]
    }

    in_shell(fn ->
      GettextTemplates.merge(core, other, %{
        "mishka_gervaz.pot" => %Expo.Messages{messages: [published]}
      })
    end)

    assert templates(core) == before
  end

  defp write_core_templates(core) do
    write_template(core, "default.pot", [
      %Expo.Message.Singular{
        msgid: ["Draft"],
        references: [[{"lib/mishka_cms_core/core.ex", 1}]],
        flags: [["elixir-autogen", "elixir-format"]]
      }
    ])

    write_template(core, "mishka_gervaz.pot", [
      %Expo.Message.Singular{
        msgid: ["Published"],
        references: [[{"../other_extension/lib/other.ex", 3}]],
        flags: [["elixir-autogen", "elixir-format"]]
      },
      %Expo.Message.Singular{
        msgid: ["No longer marked"],
        references: [[{"../fixture_extension/lib/fixture_extension/gone.ex", 1}]],
        flags: [["elixir-autogen", "elixir-format"]]
      },
      %Expo.Message.Singular{msgid: ["Written by hand"]}
    ])
  end

  defp write_template(core, file, messages) do
    path = Path.join([core, "priv/gettext", file])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Expo.PO.compose(%Expo.Messages{headers: [""], messages: messages}))
  end

  defp write_extension(extension) do
    File.mkdir_p!(Path.join(extension, "lib/fixture_extension"))
    File.write!(Path.join(extension, "mix.exs"), @mix_exs)
    File.write!(Path.join(extension, "lib/fixture_extension/labels.ex"), @labels)
    File.write!(Path.join(extension, "lib/fixture_extension/card.ex"), @card)
  end

  defp in_shell(fun) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    fun.()
    Mix.shell(shell)
  end

  defp templates(core) do
    core
    |> Path.join("priv/gettext/*.pot")
    |> Path.wildcard()
    |> Map.new(&{Path.basename(&1), File.read!(&1)})
  end

  defp parse(content), do: Expo.PO.parse_string!(content)

  defp find(template, msgid),
    do: Enum.find(template.messages, &(IO.iodata_to_binary(&1.msgid) == msgid))

  defp references(%Expo.Messages{} = template, msgid), do: references(find(template, msgid))
  defp references(message), do: List.flatten(message.references)

  defp core?(message),
    do:
      Enum.any?(references(message), fn {file, _line} -> not String.starts_with?(file, "../") end)

  defp keys(template), do: Enum.map(template.messages, &Expo.Message.key/1)
end
