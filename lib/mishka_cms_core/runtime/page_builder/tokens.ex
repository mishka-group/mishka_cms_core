# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.Tokens do
  @moduledoc """
  The design tokens a site actually renders from — read out of, and written back into, its own
  stylesheet rows.

  ## Where a token lives

  A site's CSS is not one file. `Stylesheet` rows — global ones and the site's own — are merged by
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler` into a single compiled sheet, ordered
  `app_base → theme → base → custom` and then by priority. The first two are injected BEFORE class
  generation, because that is where the tokens are declared and Tailwind needs them to exist before
  it resolves `bg-danger-light`.

  Inside a `:theme` row the shape the kit ships is two blocks:

      :root { --danger-light: #de1135; … }        ← the values
      @theme { --color-danger-light: var(--danger-light); … }   ← the Tailwind names

  So a token IS a custom-property declaration in a `:root` block, and changing one changes every
  component on the site that resolves through it. That is what makes this worth editing visually
  rather than through a text area: `--danger-light` is referenced by every danger variant of every
  component, and nothing else in the editor can express "make danger warmer".

  ## What this module does NOT do

  It does not invent tokens, and it does not touch the `@theme` block. A name that is not already
  declared has no meaning to the compiled CSS, and rewriting the mapping block would decouple the
  Tailwind colour from the value it points at. Adding a genuinely new token is a stylesheet edit,
  which the Stylesheets admin page already owns.
  """

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace.Token
  alias MishkaCmsCore.Runtime.Stylesheet

  require Ash.Query

  # Only these two carry tokens. `:base` and `:custom` are ordinary CSS that RESOLVES tokens; a
  # `--foo` declared there arrives after class generation and Tailwind never sees it.
  @token_kinds [:app_base, :theme]

  @declaration ~r/(--[a-z0-9-]+)\s*:\s*([^;{}]+);/i

  # `@theme { --color-danger-light: var(--danger-light); }` is a MAPPING, not a token: it gives the
  # Tailwind colour a name and points it at the value declared above. Editing it would decouple the
  # two, so the Studio lists what the mapping resolves to and leaves the mapping alone.
  @theme_block ~r/@theme\s*\{[^{}]*\}/s

  # The one row per site this module owns outright. Named rather than guessed at, so an override
  # never lands in the middle of a stylesheet somebody else wrote.
  @override_name "studio-tokens"
  @override_content ":root {\n}\n"

  @override_attrs %{
    name: @override_name,
    kind: :theme,
    description: "Design tokens this site overrides, written by the Studio.",
    active: true,
    priority: 100
  }

  # WHAT THE BUILDER WRITES IT GENERATED: the stylesheet row is written by whoever may open a
  # builder, rather than by the stylesheet area alone. See `MishkaCmsCore.Runtime.Stylesheet`.
  @builder %{page_code: :builder}

  # Only the block this module writes, anchored to the start of a line so a `:root` nested inside a
  # media query — where a declaration would be conditional — is never the one appended to.
  @override_root ~r/^:root\s*\{/m

  @doc """
  Every token the site declares, newest sheet last so a site row overrides a global one.

  `usage` counts how many other declarations reference the token — `--danger-hover-light:
  var(--danger-light)` counts once — which is what the Studio dims an unused token by.
  """
  @spec list(String.t() | nil) :: [Token.t()]
  def list(site_id) do
    sheets = token_sheets(site_id)
    source = Enum.map_join(sheets, "\n", & &1.content)

    sheets
    # WHICH SHEET SAID IT, not just what was said. The sheets are already in cascade order and each
    # one already knows whether it belongs to a site or to the whole install — and this reduced them
    # to one string and threw that away, one line before `custom?` needed it. So every token was
    # `custom?: false`, and with it went the Custom chip, the Custom filter, the highlighted row and
    # the Studio's own toolbar badge: four surfaces that have never once been seen.
    |> Enum.reduce(%{}, fn sheet, acc ->
      sheet.content
      |> without_theme_block()
      |> declarations()
      # A later declaration of the same name wins, exactly as it does in the browser.
      |> Enum.reduce(acc, fn {key, value}, inner ->
        Map.put(inner, key, {value, not is_nil(sheet.site_id)})
      end)
    end)
    |> Enum.map(fn {key, {value, custom?}} -> token(key, value, source, custom?) end)
    |> Enum.sort_by(&{category_order(&1.category), &1.key})
  end

  @doc """
  Sets a token's value in the sheet that declares it, as `actor`, and recompiles the site's CSS.

  Refuses a name the site does not already declare: a token nothing resolves through is a line of
  dead CSS, and silently adding one would look like it worked. The write is the builder's own, so
  it is made by whoever may open a builder rather than by the stylesheet area alone; with no actor
  it is refused.
  """
  @spec put(map() | nil, String.t() | nil, String.t(), String.t(), String.t() | nil) ::
          {:ok, Token.t()} | {:error, term()}
  def put(actor, site_id, key, value, site_name \\ nil)

  def put(nil, _site_id, _key, _value, _site_name), do: {:error, :forbidden}

  def put(actor, site_id, key, value, site_name) do
    with {:ok, value} <- sane_value(value),
         {:ok, target} <- target_sheet(site_id, key),
         {:ok, sheet} <- write(target, key, value, actor) do
      recompile(site_name)
      # The sheet this landed in decides it, the same way `list/1` decides it.
      {:ok, token(key, value, sheet.content, not is_nil(sheet.site_id))}
    end
  end

  # A SITE'S FIRST OVERRIDE IS ONE WRITE: its sheet is created holding the declaration, rather than
  # created and then updated — a row just created carries its tenant, which a master's update refuses.
  defp write({:override, site_id}, key, value, actor),
    do: create_override_sheet(site_id, put_declaration(@override_content, key, value), actor)

  defp write(sheet, key, value, actor),
    do: update_sheet(sheet, put_declaration(sheet.content, key, value), actor)

  @doc "The token declarations in a blob of CSS, in source order."
  @spec declarations(String.t()) :: [{String.t(), String.t()}]
  def declarations(source) when is_binary(source) do
    @declaration
    |> Regex.scan(source)
    |> Enum.map(fn [_line, key, value] -> {key, String.trim(value)} end)
  end

  def declarations(_source), do: []

  @doc "The same CSS with its `@theme` mapping blocks removed."
  @spec without_theme_block(String.t()) :: String.t()
  def without_theme_block(source) when is_binary(source),
    do: Regex.replace(@theme_block, source, "")

  def without_theme_block(_source), do: ""

  defp token_sheets(site_id) do
    Stylesheet
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(kind in ^@token_kinds)
    |> scope_to_site(site_id)
    # EVERY sheet, because the cap was applied BEFORE the sort. Past a hundred rows the ones that came
    # back were whatever order the database chose, so a site's own theme could be dropped and its
    # tokens simply stopped appearing in Studio — a shorter list, no error, nothing to notice. The
    # sort below is what decides which declaration wins, and it can only decide between rows it was
    # given. `:read_any` makes pagination optional; `:master_read` would raise on this.
    |> Ash.read!(page: false)
    |> Enum.sort_by(&Stylesheet.load_order/1)
  end

  # Without a site there is nothing to add to the global sheets, and `site_id == ^nil` is a
  # comparison Ash warns about precisely because it can never match.
  defp scope_to_site(query, nil), do: Ash.Query.filter(query, is_nil(site_id))

  defp scope_to_site(query, site_id),
    do: Ash.Query.filter(query, is_nil(site_id) or site_id == ^site_id)

  defp declaring_sheet(site_id, key) do
    site_id
    |> token_sheets()
    |> Enum.reverse()
    |> Enum.find(fn sheet -> Regex.match?(declaration_regex(key), sheet.content || "") end)
    |> case do
      nil -> {:error, :unknown_token}
      sheet -> {:ok, sheet}
    end
  end

  # A SHARED SHEET IS EVERY SITE'S, AND THE STUDIO IS OPEN ON ONE OF THEM. The kit ships its tokens
  # in a global `:theme` row, so nearly every token a site can see is declared there — and writing
  # the sheet that declares it meant one site's Studio changed `--danger-light` for the whole
  # installation, silently, with nothing in any other editor to say where it came from.
  #
  # The cascade already answers this. A site's own `:theme` row loads after the global ones
  # (`Stylesheet.load_order/1` ranks a site-scoped row second), so an override is nothing more than
  # the same declaration in the site's own sheet — which is what `put/4` writes now, creating that
  # sheet the first time a token is overridden. The shared row is never edited from inside a site.
  #
  # A MASTER EDITING WITHOUT A SITE still writes the shared row, because that is the document they
  # have open: `site_id` nil is the global scope, not a missing one.
  defp target_sheet(site_id, key) when is_binary(site_id) do
    case declaring_sheet(site_id, key) do
      {:ok, %{site_id: nil}} -> override_sheet(site_id)
      other -> other
    end
  end

  defp target_sheet(site_id, key), do: declaring_sheet(site_id, key)

  # One row per site, found by name and made on demand. Its whole content is this module's, which is
  # what lets a declaration be appended without guessing at the shape of somebody else's CSS — the
  # reason the override does not simply go into whichever site sheet happens to exist.
  defp override_sheet(site_id) do
    Stylesheet
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and name == ^@override_name)
    |> Ash.read!(page: false)
    |> List.first()
    |> case do
      nil -> {:ok, {:override, site_id}}
      sheet -> {:ok, sheet}
    end
  end

  # A MASTER NAMES THE SITE, A TENANT IS ONE — the split every `global? true` resource makes.
  defp create_override_sheet(site_id, content, %{site_id: nil} = actor) do
    Stylesheet
    |> Ash.Changeset.for_create(:master_create, override_attrs(content, site_id),
      actor: actor,
      context: @builder
    )
    |> Ash.create()
  end

  defp create_override_sheet(site_id, content, actor) do
    Stylesheet
    |> Ash.Changeset.for_create(:create, Map.delete(override_attrs(content, site_id), :site_id),
      actor: actor,
      tenant: site_id,
      context: @builder
    )
    |> Ash.create()
  end

  defp override_attrs(content, site_id),
    do: Map.merge(@override_attrs, %{content: content, site_id: site_id})

  defp update_sheet(sheet, content, %{site_id: nil} = actor) do
    sheet
    |> Ash.Changeset.for_update(:master_update, %{content: content},
      actor: actor,
      tenant: nil,
      context: @builder
    )
    |> Ash.update()
  end

  defp update_sheet(sheet, content, actor) do
    sheet
    |> Ash.Changeset.for_update(:update, %{content: content},
      actor: actor,
      tenant: sheet.site_id,
      context: @builder
    )
    |> Ash.update()
  end

  # Replace where the sheet already declares the token, append where it does not — the second is what
  # a fresh override sheet needs, and the first is every edit after it.
  defp put_declaration(content, key, value) do
    case Regex.match?(declaration_regex(key), content || "") do
      true -> replace_declaration(content, key, value)
      false -> append_declaration(content || "", key, value)
    end
  end

  defp replace_declaration(content, key, value) do
    Regex.replace(declaration_regex(key), content, "\\1: #{value};", global: false)
  end

  defp append_declaration(content, key, value) do
    case Regex.replace(@override_root, content, "\\0\n  #{key}: #{value};", global: false) do
      ^content -> content <> "\n:root {\n  #{key}: #{value};\n}\n"
      appended -> appended
    end
  end

  defp declaration_regex(key) do
    ~r/(#{Regex.escape(key)})\s*:\s*[^;]+;/i
  end

  # A value is written verbatim into a stylesheet, so it may not carry a `;` or `}` out of its own
  # declaration and it may not open a comment. This is the whole of the sanitisation: everything
  # else — `#fff`, `var(--x)`, `1.25rem`, `rgba(0,0,0,.5)` — is a legitimate token value and
  # guessing at a grammar would reject valid CSS.
  defp sane_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, :blank}
      String.contains?(trimmed, [";", "}", "{", "/*", "*/"]) -> {:error, :invalid_value}
      String.length(trimmed) > 200 -> {:error, :too_long}
      true -> {:ok, trimmed}
    end
  end

  defp sane_value(_value), do: {:error, :invalid_value}

  defp token(key, value, source, custom?) do
    Token.new!(%{
      category: category(value),
      label: label(key),
      key: String.trim_leading(key, "--"),
      value: value,
      usage: usage(key, source),
      custom?: custom?,
      glyph: glyph(category(value))
    })
  end

  # The Studio groups by what a value IS, because that is what its control has to be: a colour needs
  # a swatch, a length needs a number. The kit names tokens by role (`--danger-light`), not by type.
  defp category(value) do
    cond do
      Regex.match?(~r/^(#|rgb|hsl|oklch|color-mix)/i, value) -> "color"
      Regex.match?(~r/^var\(--color-/i, value) -> "color"
      Regex.match?(~r/(rem|px|em|ch|vw|vh)\b/i, value) -> "space"
      Regex.match?(~r/^\d+(\.\d+)?$/, value) -> "space"
      Regex.match?(~r/(ease|cubic-bezier|ms\b|s\b)/i, value) -> "motion"
      Regex.match?(~r/shadow|rgba/i, value) -> "shadow"
      true -> "type"
    end
  end

  defp glyph("type"), do: "Aa"
  defp glyph(_category), do: ""

  defp label(key) do
    key
    |> String.trim_leading("--")
    |> String.replace("-", " ")
    |> String.trim()
    |> String.capitalize()
  end

  # How many OTHER declarations resolve through this one. `var(--danger-light)` appears in the
  # `@theme` mapping and in every sibling that reuses it.
  defp usage(key, source) do
    ~r/var\(\s*#{Regex.escape(key)}\s*[,)]/i
    |> Regex.scan(source)
    |> length()
  end

  defp category_order("color"), do: 0
  defp category_order("type"), do: 1
  defp category_order("space"), do: 2
  defp category_order("radius"), do: 3
  defp category_order("shadow"), do: 4
  defp category_order("motion"), do: 5
  defp category_order(_other), do: 6

  # The token only means something once the site's CSS is rebuilt with it. Without a site name there
  # is nothing to rebuild — a global sheet edited outside any site's context — and the next compile
  # of each site picks it up.
  defp recompile(nil), do: :ok

  defp recompile(site_name) do
    TailwindCompiler.compile(site_name)
    :ok
  rescue
    error -> {:error, error}
  end
end
