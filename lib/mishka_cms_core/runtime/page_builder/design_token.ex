# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.DesignToken do
  @moduledoc """
  The Studio's Design tokens tab, as a Gervaz table.

  ## A resource with no table behind it

  A design token is not a row anywhere. It is a custom-property declaration inside a `Stylesheet`
  row's CSS text, parsed out by `MishkaCmsCore.Runtime.PageBuilder.Tokens`. Gervaz needs an Ash
  RESOURCE to build a table — it reads the attributes, the filters and the actions off one — but it
  never needs a data layer, so this resource has none. Ash defaults that to
  `Ash.DataLayer.Simple`, and the `on_load` hook hands it the parsed tokens with
  `Ash.DataLayer.Simple.set_data/2`.

  Everything downstream then works unchanged: Simple applies the filter, the sort, the limit and the
  offset in memory, so the category chips and load-more are real Gervaz features rather than markup
  that reimplements them.

  ## What it cannot do

  Simple has no aggregate support, so nothing here may ask for a count — `type :numbered` or
  `show_total true` would raise. Load-more does not count: it reads `page_size + 1` rows and infers
  "there is more" from the extra one, which is why it is the pagination this table uses.

  The site whose stylesheets are read arrives as `path_params[:site_id]`, the same channel the draft
  picker scopes itself through.

  See `MishkaCmsCoreWeb.Templates.StudioTokens`, which owns the whole of this table's markup.
  """

  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    extensions: [MishkaGervaz.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias MishkaCmsCore.Runtime.PageBuilder.Marketplace
  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  mishka_gervaz do
    table do
      identity do
        name :studio_tokens
        route "/admin/dashboard/runtime/builder"
        stream_name :studio_tokens
      end

      source do
        actions do
          read :read
          get :read
        end
      end

      # Load-more rather than pages: 253 tokens is a list you scroll, not one you page through, and
      # `Ash.DataLayer.Simple` cannot count — load-more never asks it to.
      pagination do
        type :load_more
        page_size 30

        # `show_total` defaults to TRUE, and a total is a count — which `Ash.DataLayer.Simple`
        # cannot do. Leaving it on is what made the table raise "Aggregate queries not supported"
        # even with a `countable: false` read. The design shows no total either.
        ui do
          show_total false
        end
      end

      columns do
        default_sort [{:category, :asc}, {:key, :asc}]

        column :label do
          label fn -> dgettext("mishka_gervaz", "Label") end
        end
      end

      filters do
        filter :search, :text do
          fields [:key, :label, :value]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        # The "Custom" chip is a filter of its own, not a category: a custom token still belongs to
        # colour or space, it just came from this site rather than the kit.
        filter :custom, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Custom") end
          end
        end

        filter :category, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Color"), "color"},
              {dgettext("mishka_gervaz", "Type"), "type"},
              {dgettext("mishka_gervaz", "Space"), "space"},
              {dgettext("mishka_gervaz", "Radius"), "radius"},
              {dgettext("mishka_gervaz", "Shadow"), "shadow"},
              {dgettext("mishka_gervaz", "Motion"), "motion"},
              {dgettext("mishka_gervaz", "Screen"), "screen"}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Category") end
          end
        end
      end

      # The list is read from the site's stylesheets on every load. There is nothing to subscribe to
      # — a token changes when someone edits it here, and that edit reloads the table itself.
      realtime do
        enabled false
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No design tokens found"),
                  icon: "hero-swatch"

      hooks do
        # The whole integration: no database, no manual read action — the rows are handed to
        # `Ash.DataLayer.Simple`, which then honours the filter, sort and paging Gervaz built onto
        # the query.
        on_load fn query, state ->
          {:cont, Ash.DataLayer.Simple.set_data(query, rows(state))}
        end
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.StudioTokens
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        # The design groups tokens under category headings, and a LiveView stream is one flat
        # container that appends — it cannot express a heading. So this template renders from
        # `state.loaded_records` instead of `@streams`, and load-more needs every page kept rather
        # than just the newest one.
        keep_loaded_records true
      end
    end
  end

  actions do
    read :read do
      primary? true

      # `countable: false` is the load-bearing part. `Ash.DataLayer.Simple` has no aggregate
      # support, so ANY count raises "Aggregate queries not supported" — which is exactly what
      # happened the first time this table rendered. Load-more never needs one: it reads
      # `limit + 1` rows and infers "there is more" from the extra.
      pagination offset?: true, default_limit: 30, max_page_size: 500, countable: false
    end
  end

  # A TOKEN IS A LINE OF A STYLESHEET, so it is read as a stylesheet is: by anyone under the
  # surface the request came from. Changing one is `Tokens.put/4`'s, as the builder.
  policies do
    policy action_type(:read) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions, under: :surface}
    end
  end

  attributes do
    # The declaration's own name is its identity — there is no row and therefore no uuid, and two
    # tokens cannot share a name because the later declaration wins in the browser too.
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :key, :string, public?: true
    attribute :label, :string, public?: true
    attribute :value, :string, public?: true
    attribute :category, :string, public?: true
    attribute :glyph, :string, public?: true
    attribute :usage, :integer, public?: true

    # Not `custom?` — an Ash attribute may not end in `?`.
    attribute :custom, :boolean, public?: true
  end

  @doc """
  The tokens of one site, in the shape this resource declares.

  A site with no theme stylesheet has no tokens, and an empty Studio is not what that should look
  like — so it falls back to the sample set, exactly as the hand-rolled list did before this became
  a table.
  """
  @spec rows(map()) :: [struct()]
  def rows(state) do
    site_id = site_id(state)

    site_id
    |> Tokens.list()
    |> case do
      [] -> Marketplace.tokens(site_id)
      tokens -> tokens
    end
    |> Enum.map(fn token ->
      struct(__MODULE__, %{
        id: token.key,
        key: token.key,
        label: token.label,
        value: token.value,
        category: token.category,
        glyph: token.glyph,
        usage: token.usage,
        custom: token.custom?
      })
    end)
  end

  defp site_id(%{path_params: %{site_id: site_id}}) when is_binary(site_id), do: site_id
  defp site_id(_state), do: nil
end
