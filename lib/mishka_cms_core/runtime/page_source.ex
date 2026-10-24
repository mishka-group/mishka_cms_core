# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageSource do
  @moduledoc """
  The rows a page shows, read once for the request and handed to everything that draws them: the
  head (`MishkaCmsCore.Runtime.Seo`), the frame (`MishkaCmsCore.Runtime.SiteLayout`) and the page's
  own blocks.

  A page that shows a record is drawn by three readers: the plugin on `Seo.event/0` for its head,
  the plugin on `SiteLayout.event/0` for its languages and its bar, and the blocks of its template
  for the record itself. Each of them asked the database for the same rows on its own. A plugin on
  `event/0` reads them once, before the other two run, and every one of them is handed what it read.

  ## The event

  `MishkaCmsWeb.RuntimeLive` calls `assign_source/1` in every `handle_params/3`, once the page, its
  language, `@query_params` and the visitor are known, and before the frame and the head. It fires
  `event/0` with the map `given/2` builds and assigns the answer as `@page_source`:

    * `page`, `section`, `record`, `extra`, `params`, `language`, `site_id`: as
      `MishkaCmsCore.Runtime.SiteLayout` hands them to its plugins. Read only.
    * `current_user`: the signed-in visitor, or `nil` for a guest. The rows are read as them.
    * `held`: what this LiveView's previous address read, for the same visitor, or `nil`. A live
      patch that stays on the same record (another page of a list, another version) takes from it
      what the new address did not change, rather than reading it again.
    * `source`: `nil`.

  A plugin answers for the pages it owns, matched as a frame plugin matches them, by putting its
  rows under `source`, and hands every other page back untouched, before anything is read. What it
  puts there is its own: core never looks inside it. It reaches, unchanged:

    * the plugins on `Seo.event/0`, as `source` in the map they are handed (`Seo.given/2`);
    * the plugins on `SiteLayout.event/0`, as `source` (`SiteLayout.given/2`);
    * the page's template, as `@page_source`, which hands it to its blocks:

          <.component component_name="doc-section" page_source={assigns[:page_source]} … />

  `{:reply, :halt, given}` keeps later plugins from answering for a page this one owns. A plugin
  that raises, or an event whose plugins cannot run, leaves the page with no source, and every
  reader reads for itself as it does without one.

  ## The rules a source keeps

    * IT IS READ AS THE VISITOR, through the public actions and the policies the blocks read with:
      the same locks, the same lock inherited from what a record is filed under, the same page lock.
      It is never broader than what that visitor may see, so a reader handed it shows nothing a
      read of its own would not have. A read made as the system belongs only where nothing of it
      reaches the visitor: the lock a record's page refuses the visitor by.
    * IT IS THE VISITOR'S: it is read for one visitor (`visitor_id/1`) and says which, and a block
      handed one read for somebody else reads for itself.
    * IT LIVES FOR ONE ADDRESS: it is read again in every `handle_params/3`, and lives in the
      LiveView's assigns and nowhere else. A task a block starts is handed what it needs as an
      argument, not the LiveView.
    * A BLOCK STILL STANDS ON ITS OWN. On the builder's canvas, in a preview, on a page whose
      template does not hand it over, and for any read it was not given, a block reads as it
      always did. One handed a source takes from it only rows read for exactly what it would read
      itself.

  `page_source` is handed only to a component that declares the attribute
  (`MishkaCmsCore.Runtime.LiveViewHelpers`): one an admin keeps on an older kit is drawn as if the
  template did not name it, rather than with the rows in its global attributes.
  """

  alias MishkaCmsCore.Runtime.Seo
  alias MishkaInstaller.Event.Hook

  @event "runtime:page:source"

  # Where `assign_source/1` keeps whom the source it assigned was read for, so the next address
  # hands it back as `held` only to the same visitor. Private, because nothing renders it.
  @read_for :mishka_cms_page_source_visitor

  @doc "The event a page's rows are read through, once per `handle_params/3`."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The map `event/0` is called with for `page`, before any plugin has answered. See the moduledoc
  for each key.

  `page` is the `:page` section of the page module's `__page_information__/0`, with `language` the
  language of this response. Options: `:site_id`, `:current_user`, `:extra` (the page's `extra`),
  `:params` (`@query_params`) and `:held`.
  """
  @spec given(map(), keyword()) :: map()
  def given(page, opts) do
    extra = Keyword.get(opts, :extra) || %{}

    %{
      page: page,
      section: Map.get(page, :section),
      record: Seo.record_of(extra),
      extra: extra,
      params: Keyword.get(opts, :params) || %{},
      language: Map.get(page, :language),
      site_id: Keyword.get(opts, :site_id),
      current_user: Keyword.get(opts, :current_user),
      held: Keyword.get(opts, :held),
      source: nil
    }
  end

  @doc """
  What `page` is read from: `given/2`, then the plugins on `event/0`, then `accept/1`. Takes the
  options `given/2` takes.
  """
  @spec source(map(), keyword()) :: term()
  def source(page, opts) do
    @event
    |> Hook.call(given(page, opts))
    |> accept()
  end

  @doc """
  The `source` of the map a plugin on `event/0` returned; `nil` for anything but a map.
  """
  @spec accept(term()) :: term()
  def accept(%{source: source} = answer) when not is_struct(answer), do: source
  def accept(_not_an_answer), do: nil

  @doc """
  The page's source, assigned to `socket` as `@page_source`.

  For `MishkaCmsWeb.RuntimeLive`, which calls it in `handle_params/3` once the page, its language,
  `@query_params` and `@current_user` are assigned, and before `SiteLayout.assign_frame/1` and the
  head, which are handed it. The source this socket held is handed to the plugins as `held` only
  when it was read for the same visitor.
  """
  @spec assign_source(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_source(%Phoenix.LiveView.Socket{assigns: assigns} = socket) do
    visitor = assigns |> Map.get(:current_user) |> visitor_id()

    source =
      source(assigns.page,
        site_id: assigns |> Map.get(:private, %{}) |> Map.get(:site_id),
        current_user: Map.get(assigns, :current_user),
        extra: Map.get(assigns, :extra),
        params: Map.get(assigns, :query_params),
        held: held(socket, visitor)
      )

    socket
    |> Phoenix.LiveView.put_private(@read_for, {:read_for, visitor})
    |> Phoenix.Component.assign(:page_source, source)
  end

  defp held(%{private: private, assigns: assigns}, visitor) do
    case Map.get(private, @read_for) do
      {:read_for, ^visitor} -> Map.get(assigns, :page_source)
      _somebody_else_or_nothing -> nil
    end
  end

  @doc """
  Whom a source is read for: the signed-in visitor's id, or `nil` for a guest. A plugin keeps it
  in what it answers, and a block compares it with its own `current_user`'s before taking a row.
  """
  @spec visitor_id(term()) :: term()
  def visitor_id(%{id: id}), do: id
  def visitor_id(_guest), do: nil
end
