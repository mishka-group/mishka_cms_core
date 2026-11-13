# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.HeadCodes do
  @moduledoc """
  The code a site puts in the `<head>` of its public pages: an analytics script, a search engine's
  verification tag, a font link. A site's admins write it as `MishkaCmsCore.Runtime.HeadCode`
  entries, and extensions add theirs through the same event.

  ## One path for both: `runtime:page:head`

  `head/4` fires `event/0` as a public page's head is drawn, with

      %{site_id: site_id, path: "/pricing", page: page, nonce: nonce, items: []}

  `page` is the `:page` section of the page module's `__page_information__/0` (its `path` is the
  page's pattern), and `nonce` the response's CSP nonce. A plugin appends items to `items` and
  returns the map. An item is

      %{tag: "script", attrs: [{"src", "https://plausible.io/js/script.js"}], content: nil}

  where a script's `content` is its code and a noscript's a list of meta and link items. A plugin
  may give an item a `key`: the items of one key are added and removed together when a visitor moves
  between pages without a reload (see Live navigation below). The site's own entries reach the head
  through `MishkaCmsCore.Runtime.SiteHeadCode`, a plugin on this event, keyed by their id.

  Every item, a plugin's and an entry's alike, passes `accept/1` before it is drawn.

  ## What is kept

  The code is parsed (`parse/1`, with `:mochiweb_html`, which reads a script's body as raw text) and
  never trusted as HTML:

    * only `script`, `meta`, `link` and `noscript` are kept, and a noscript keeps only its meta and
      link tags;
    * an attribute named `on...`, `nonce` or `http-equiv` is dropped, and so is a `src` or `href`
      that is not an `http(s)` address or a path on the site;
    * a script with neither a `src` nor any code, and a link with no `href`, are dropped;
    * `</script` and `<!--` inside a script's code are written as `<\\/script` and `<\\!--`, so the
      code cannot close its own element.

  An entry is refused when its code is over `max_code_bytes/0` bytes, keeps nothing, or carries an
  attribute these rules would drop, with a message naming the attribute and why it cannot stay.

  ## The Content Security Policy

  Every script is drawn with the response's nonce, so it runs whatever its `src`. An entry's
  `origins` (each `https://host[:port]`) are what the script then reaches: they are added to
  `script-src` and `connect-src` on that site's public pages by
  `MishkaCmsWeb.Runtime.Plugs.SecurityHeaders`, which asks `origins/1`. The policy is written before
  the page is known, so a plugin declares its origins up front on `origins_event/0`:

      %{site_id: site_id, origins: []}

  ## No query per request

  The published entries of every site are held in `MishkaCmsCore.Runtime.States.SiteState`, already
  parsed, and kept current by `MishkaCmsCore.Runtime.Resources.Notifiers.HeadCodes` on the writing
  node and by its broadcasts on the others. Neither the head nor the policy reads the database.

  ## Live navigation

  The head is drawn once per HTTP response. When a visitor moves to another page inside the socket,
  the page's LiveView pushes `payload/2` of the new page's items as `mishka:head`, and the client
  adds the items of each key it does not have yet and removes the ones of a key no longer listed. An
  item on every page is listed on every page, so it is never drawn twice. A script removed this way
  has already run, and what it loaded stays loaded until the next full page load.

  Admin and editor pages never get any of this: only a public page draws it.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsWeb.Runtime.Plugs.SecurityHeaders
  alias MishkaInstaller.Event.Hook

  @event "runtime:page:head"
  @origins_event "runtime:page:head_origins"

  @tags ["script", "meta", "link", "noscript"]
  @noscript_tags ["meta", "link"]
  @attribute ~r/\A[a-z][a-z0-9:_.-]*\z/i
  @address_attributes ["src", "href"]

  @max_code_bytes 20_000
  @max_entries 20

  @scopes [
    {:all, dgettext_noop("mishka_gervaz", "All pages")},
    {:only, dgettext_noop("mishka_gervaz", "Only these pages")},
    {:except, dgettext_noop("mishka_gervaz", "All pages except these")}
  ]

  @typedoc "One tag of the head, as `event/0` passes it and `tags/1` draws it."
  @type item :: %{
          required(:tag) => String.t(),
          required(:attrs) => [{String.t(), String.t()}],
          required(:content) => String.t() | [item()] | nil,
          optional(:key) => String.t()
        }

  @doc "The event a public page's head items are gathered on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The event a plugin declares the origins its head items reach on, once per public request."
  @spec origins_event() :: String.t()
  def origins_event, do: @origins_event

  @doc "The longest code one entry may hold, in bytes."
  @spec max_code_bytes() :: pos_integer()
  def max_code_bytes, do: @max_code_bytes

  @doc "How many entries one site may hold."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc "The scopes an entry may have, `{label, value}`, for the admin form."
  @spec scope_options() :: [{String.t(), atom()}]
  def scope_options,
    do: Enum.map(@scopes, fn {scope, label} -> {translate(label), scope} end)

  @doc "The name of `scope` in the reader's language."
  @spec scope_label(atom()) :: String.t()
  def scope_label(scope) do
    case List.keyfind(@scopes, scope, 0) do
      {^scope, label} -> translate(label)
      nil -> to_string(scope)
    end
  end

  defp translate(label), do: Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label)

  @doc """
  The scope the admin form holds now, `:all` until one is chosen: what decides whether it shows the
  paths. `state` is the form's gervaz state.
  """
  @spec form_scope(map()) :: atom()
  def form_scope(%{form: %Phoenix.HTML.Form{} = form}) do
    case Phoenix.HTML.Form.input_value(form, :scope) do
      scope when scope in [:only, :except] -> scope
      scope when scope in ["only", "except"] -> String.to_existing_atom(scope)
      _all -> :all
    end
  end

  def form_scope(_state), do: :all

  @doc """
  Whether `user` writes head code: a master (no `site_id`) holding
  `admin:dashboard:runtime:head_code`. The code runs for every visitor of the site, so a site user
  writes none for now, whatever it holds.
  """
  @spec writes?(map() | nil) :: boolean()
  def writes?(%{site_id: nil} = user),
    do:
      AccessPermissions.match?(AccessPermissions.with_permissions(user), %{},
        permissions: ["admin:dashboard:runtime:head_code"]
      )

  def writes?(_user), do: false

  @doc """
  The items `code` keeps, or `:error` when it keeps none. See the moduledoc for what is kept.

      parse(~s|<script defer src="https://plausible.io/js/script.js"></script><div>x</div>|)
      #=> {:ok, [%{tag: "script", attrs: [{"defer", "defer"}, {"src", "https://plausible.io/js/script.js"}], content: nil}]}
  """
  @spec parse(term()) :: {:ok, [item()]} | :error
  def parse(code) when is_binary(code) and byte_size(code) <= @max_code_bytes do
    with {:ok, nodes} <- elements(code), do: items(nodes)
  end

  def parse(_code), do: :error

  defp elements(code) do
    case :mochiweb_html.parse("<html><head>" <> code <> "</head></html>") do
      {"html", _attrs, sections} -> {:ok, Enum.flat_map(sections, &children/1)}
      _other -> :error
    end
  rescue
    _unreadable -> :error
  end

  defp children({_section, _attrs, nodes}) when is_list(nodes), do: Enum.map(nodes, &element/1)
  defp children(_text), do: []

  # An unclosed `<script>` swallows the wrapper's closing tags, and keeps nothing.
  defp element({tag, attrs, children}) when tag in @tags and is_list(attrs) do
    %{tag: tag, attrs: attrs, content: node_content(tag, children)}
  end

  defp element(_other), do: nil

  defp node_content("script", children) do
    code = children |> Enum.filter(&is_binary/1) |> Enum.join()

    case String.ends_with?(code, "</head></html>") do
      true -> :unclosed
      false -> code
    end
  end

  defp node_content("noscript", children), do: Enum.map(children, &element/1)
  defp node_content(_tag, _children), do: nil

  defp items(nodes) do
    case accept(nodes) do
      [] -> :error
      items -> {:ok, items}
    end
  end

  @doc """
  The items of `items` that may be drawn in a head, each with only its allowed attributes. Anything
  that is not an item, a script left unclosed, and an item the rules refuse are dropped.
  """
  @spec accept(term()) :: [item()]
  def accept(items) when is_list(items), do: Enum.flat_map(items, &accept_item/1)
  def accept(_items), do: []

  defp accept_item(%{tag: tag, attrs: attrs} = item) when tag in @tags and is_list(attrs) do
    attrs = Enum.flat_map(attrs, &attribute/1)

    tag
    |> kept(attrs, Map.get(item, :content))
    |> List.wrap()
    |> Enum.map(&put_key(&1, Map.get(item, :key)))
  end

  defp accept_item(_item), do: []

  defp kept("script", attrs, content) when is_binary(content) or is_nil(content) do
    code = content || ""

    case List.keymember?(attrs, "src", 0) or String.trim(code) != "" do
      true -> %{tag: "script", attrs: attrs, content: code}
      false -> nil
    end
  end

  defp kept("noscript", attrs, content) when is_list(content) do
    case content
         |> Enum.filter(&match?(%{tag: tag} when tag in @noscript_tags, &1))
         |> accept() do
      [] -> nil
      kept -> %{tag: "noscript", attrs: attrs, content: Enum.map(kept, &Map.delete(&1, :key))}
    end
  end

  defp kept("link", attrs, _content) do
    case List.keymember?(attrs, "href", 0) do
      true -> %{tag: "link", attrs: attrs, content: nil}
      false -> nil
    end
  end

  defp kept("meta", attrs, _content) when attrs != [],
    do: %{tag: "meta", attrs: attrs, content: nil}

  defp kept(_tag, _attrs, _content), do: nil

  defp put_key(item, key) when is_binary(key) and key != "", do: Map.put(item, :key, key)
  defp put_key(item, _key), do: item

  defp attribute({name, value} = attribute) do
    case refusal(attribute) do
      nil -> [{String.downcase(name), value}]
      _refused -> []
    end
  end

  defp attribute(_attribute), do: []

  defp refusal({name, value}) when is_binary(name) and is_binary(value) do
    name = String.downcase(name)

    cond do
      not String.match?(name, @attribute) -> :name
      String.starts_with?(name, "on") -> :handler
      name == "nonce" -> :nonce
      name == "http-equiv" -> :http_equiv
      name in @address_attributes and not address?(value) -> :address
      true -> nil
    end
  end

  defp refusal(_attribute), do: :name

  # The first attribute of a kept tag that `attribute/1` would drop, with why.
  defp dropped(nodes) when is_list(nodes), do: Enum.find_value(nodes, &dropped/1)

  defp dropped(%{tag: tag, attrs: attrs, content: content}),
    do: Enum.find_value(attrs, &dropped_attribute(tag, &1)) || dropped(content)

  defp dropped(_node), do: nil

  defp dropped_attribute(tag, {name, value} = attribute) do
    case refusal(attribute) do
      nil -> nil
      reason -> {reason, tag: tag, attribute: String.downcase(name), value: shorten(value)}
    end
  end

  defp shorten(value) do
    case String.length(value) > 40 do
      true -> String.slice(value, 0, 40) <> "..."
      false -> value
    end
  end

  defp address?(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["https", "http"] and is_binary(host) ->
        host != ""

      {:ok, %URI{scheme: nil, host: nil, path: "/" <> rest}} ->
        not String.starts_with?(rest, "/")

      _other ->
        false
    end
  end

  @doc """
  The validation every write of `MishkaCmsCore.Runtime.HeadCode` runs: its code is at most
  `max_code_bytes/0` bytes, no attribute of its tags is dropped, it keeps at least one tag
  (`parse/1`), its origins are origins (`origins?/1`), and a scope other than `:all` names at least
  one path, each a path on the site.
  """
  @spec check_entry(Ash.Changeset.t(), map()) :: :ok | {:error, keyword()}
  def check_entry(changeset, _context) do
    code = Ash.Changeset.get_attribute(changeset, :code)
    origins = Ash.Changeset.get_attribute(changeset, :origins) || []

    with true <- byte_size(code) <= @max_code_bytes || {:error, :size},
         {:ok, nodes} <- elements(code),
         nil <- dropped(nodes),
         {:ok, _items} <- items(nodes),
         true <- origins?(origins) || {:error, :origins},
         :ok <- check_paths(Ash.Changeset.get_attribute(changeset, :scope), changeset) do
      :ok
    else
      {:error, :size} ->
        {:error,
         field: :code,
         message: dgettext_noop("errors", "Head code can hold at most %{size} KB."),
         size: div(@max_code_bytes, 1000)}

      {reason, vars} when is_atom(reason) and is_list(vars) ->
        {:error, [field: :code, message: dropped_message(reason)] ++ vars}

      :error ->
        {:error,
         field: :code,
         message:
           dgettext_noop(
             "errors",
             "Nothing in this code can go in a page's head. Use script, meta, link or noscript tags."
           )}

      {:error, :origins} ->
        {:error,
         field: :origins,
         message:
           dgettext_noop(
             "errors",
             "Each origin is https:// and a host, with an optional port, and nothing after it."
           )}

      {:error, :paths} ->
        {:error,
         field: :paths,
         message: dgettext_noop("errors", "Add at least one page path, such as /pricing.")}
    end
  end

  defp dropped_message(:address),
    do:
      dgettext_noop(
        "errors",
        "The %{attribute} \"%{value}\" of the %{tag} tag cannot stay: it must be an http(s) address or a path on this site, such as /js/app.js."
      )

  defp dropped_message(:handler),
    do:
      dgettext_noop(
        "errors",
        "The %{attribute} of the %{tag} tag cannot stay: a page's head runs no inline handler. Put the code in a script tag."
      )

  defp dropped_message(:nonce),
    do:
      dgettext_noop(
        "errors",
        "The nonce of the %{tag} tag cannot stay: the page gives each script its own. Remove it."
      )

  defp dropped_message(:http_equiv),
    do:
      dgettext_noop(
        "errors",
        "The http-equiv of the %{tag} tag cannot stay: it could change the page's security headers. Remove it."
      )

  defp dropped_message(:name),
    do:
      dgettext_noop(
        "errors",
        "The %{tag} tag has an attribute named %{attribute}, which is not a valid name. Remove it."
      )

  defp check_paths(:all, _changeset), do: :ok

  defp check_paths(_scope, changeset) do
    case Ash.Changeset.get_attribute(changeset, :paths) || [] do
      [_one | _more] = paths ->
        if Enum.all?(paths, &String.starts_with?(&1, "/")), do: :ok, else: {:error, :paths}

      [] ->
        {:error, :paths}
    end
  end

  @doc """
  The validation a new `MishkaCmsCore.Runtime.HeadCode` runs: its site holds fewer than
  `max_entries/0` live entries, so a site's head stays small.
  """
  @spec check_room(Ash.Changeset.t(), map()) :: :ok | {:error, keyword()}
  def check_room(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :site_id) do
      site_id when is_binary(site_id) -> room(site_id)
      _no_site -> :ok
    end
  end

  defp room(site_id) do
    count =
      MishkaCmsCore.Runtime.HeadCode
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(site_id == ^site_id)
      |> Ash.count!(authorize?: false)

    case count < @max_entries do
      true ->
        :ok

      false ->
        {:error,
         field: :code,
         message:
           dgettext_noop(
             "errors",
             "This site already has %{count} head code entries, the most it may hold."
           ),
         count: @max_entries}
    end
  end

  @doc """
  Whether `origins` is a list of origins an entry may add to the policy: `https://host` or
  `https://host:port`, the rule `SecurityHeaders.frame_origins?/1` holds `security.frame_origins` to.
  """
  @spec origins?(term()) :: boolean()
  def origins?(origins), do: SecurityHeaders.frame_origins?(origins)

  @doc """
  Whether an entry of scope `scope` over `paths` belongs on a page asked for at `path`, whose stored
  pattern is `page_path`. A path matches when it is either one, exactly.
  """
  @spec applies?(atom(), [String.t()], String.t() | nil, String.t() | nil) :: boolean()
  def applies?(:all, _paths, _path, _page_path), do: true
  def applies?(:only, paths, path, page_path), do: listed?(paths, path, page_path)
  def applies?(:except, paths, path, page_path), do: not listed?(paths, path, page_path)
  def applies?(_scope, _paths, _path, _page_path), do: false

  defp listed?(paths, path, page_path),
    do: Enum.any?(paths, &(&1 == path or (is_binary(page_path) and &1 == page_path)))

  @doc """
  The map `event/0` is called with, before any plugin has answered. `page` is the page's
  information (its `path` the stored pattern), and `nonce` the response's.
  """
  @spec given(String.t() | nil, String.t() | nil, map() | nil, String.t() | nil) :: map()
  def given(site_id, path, page, nonce),
    do: %{site_id: site_id, path: path, page: page, nonce: nonce, items: []}

  @doc """
  The head items of the public page `page` of `site_id` asked for at `path`: `given/4`, the plugins on
  `event/0`, then `accept/1`. Each item without a key of its own is keyed by what it is, so the same
  item keeps one key from page to page. No query: the site's entries come from memory.
  """
  @spec head(String.t() | nil, String.t() | nil, map() | nil, String.t() | nil) :: [item()]
  def head(site_id, path, page, nonce) when is_binary(site_id) do
    @event
    |> Hook.call(given(site_id, path, page, nonce))
    |> answered()
    |> accept()
    |> Enum.map(&keyed/1)
  end

  def head(_site_id, _path, _page, _nonce), do: []

  defp answered(%{items: items}) when is_list(items), do: items
  defp answered(_answer), do: []

  defp keyed(%{key: _key} = item), do: item

  defp keyed(item),
    do: Map.put(item, :key, "x" <> Integer.to_string(:erlang.phash2(item), 36))

  @doc """
  The entries of `site_id` that reach the page stored at `page_path`, for the page's admin detail:
  each with its `id`, `name` and `scope`. An entry limited to pages reaches it when one of its paths
  is the pattern itself or an address the pattern answers, so `/en` reaches the page stored at
  `/:lang`. From memory, no query.
  """
  @spec for_page(String.t() | nil, String.t() | nil) :: [map()]
  def for_page(site_id, page_path) when is_binary(site_id) do
    languages = if Languages.captures?(page_path), do: Languages.site(site_id), else: []

    for entry <- SiteState.head_codes(site_id),
        reaches?(entry, page_path, languages),
        do: Map.take(entry, [:id, :name, :scope])
  end

  def for_page(_site_id, _page_path), do: []

  defp reaches?(%{scope: :only, paths: paths}, page_path, languages),
    do:
      Enum.any?(
        paths,
        &(&1 == page_path or WebRunTimeMetaDataState.matches?(page_path, &1, languages))
      )

  defp reaches?(entry, page_path, _languages),
    do: applies?(entry.scope, entry.paths, page_path, page_path)

  @doc """
  What extensions add to every page of `site_id`: the items of `head/4` asked with no page that are
  not the site's own entries, and the origins their plugins declare. For the admin's "From
  extensions" list.
  """
  @spec from_extensions(String.t() | nil) :: %{items: [item()], origins: [String.t()]}
  def from_extensions(site_id) when is_binary(site_id) do
    own = MapSet.new(SiteState.head_codes(site_id), & &1.id)

    %{
      items: site_id |> head(nil, nil, nil) |> Enum.reject(&MapSet.member?(own, &1.key)),
      origins: plugin_origins(site_id)
    }
  end

  def from_extensions(_site_id), do: %{items: [], origins: []}

  @doc """
  Every origin the head code of `site_id` reaches: its published entries' and the ones plugins on
  `origins_event/0` declare, each once. What `SecurityHeaders` adds to `script-src` and
  `connect-src` on the site's public pages. No query.
  """
  @spec origins(String.t() | nil) :: [String.t()]
  def origins(site_id) when is_binary(site_id) do
    site_id
    |> SiteState.head_codes()
    |> Enum.flat_map(& &1.origins)
    |> Enum.concat(plugin_origins(site_id))
    |> Enum.uniq()
  end

  def origins(_site_id), do: []

  defp plugin_origins(site_id) do
    case Hook.call(@origins_event, %{site_id: site_id, origins: []}) do
      %{origins: origins} when is_list(origins) ->
        origins |> Enum.filter(&origins?([&1])) |> Enum.uniq()

      _no_answer ->
        []
    end
  end

  @doc """
  `items` as the `mishka:head` push carries them to the client, with the response's `nonce` the
  client gives each script it adds.
  """
  @spec payload([item()], String.t() | nil) :: map()
  def payload(items, nonce) do
    %{
      nonce: nonce,
      items:
        Enum.map(items, fn item ->
          %{
            key: item.key,
            tag: item.tag,
            attrs: Map.new(item.attrs),
            content: payload_content(item.content)
          }
        end)
    }
  end

  defp payload_content(content) when is_binary(content), do: safe_script(content)
  defp payload_content(_content), do: nil

  @doc """
  Draws `items` in a head: each script with `csp_nonce`, and every tag marked `data-mishka-head` with
  its item's key.
  """
  attr :items, :list, default: []
  attr :csp_nonce, :string, default: nil

  def tags(assigns) do
    ~H"""
    <.head_item :for={item <- @items} item={item} nonce={@csp_nonce} />
    """
  end

  attr :item, :map, required: true
  attr :nonce, :string, default: nil

  # The code is written by a master and kept by `accept/1`, which makes sure it cannot close its own
  # element.
  # sobelow_skip ["XSS.Raw"]
  defp head_item(%{item: %{tag: "script"}} = assigns) do
    ~H"""
    <script {@item.attrs} nonce={@nonce} data-mishka-head={@item[:key]}>
      <%= Phoenix.HTML.raw(safe_script(@item.content)) %>
    </script>
    """
  end

  defp head_item(%{item: %{tag: "noscript"}} = assigns) do
    ~H"""
    <noscript {@item.attrs} data-mishka-head={@item[:key]}><.head_item
      :for={inner <- @item.content}
      item={inner}
    /></noscript>
    """
  end

  defp head_item(%{item: %{tag: "meta"}} = assigns) do
    ~H"""
    <meta {@item.attrs} data-mishka-head={@item[:key]} />
    """
  end

  defp head_item(%{item: %{tag: "link"}} = assigns) do
    ~H"""
    <link {@item.attrs} data-mishka-head={@item[:key]} />
    """
  end

  defp safe_script(code) when is_binary(code) do
    code
    |> String.replace(~r/<\/(script)/i, "<\\\\/\\1")
    |> String.replace("<!--", "<\\!--")
  end

  defp safe_script(_code), do: ""
end
