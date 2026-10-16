# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement do
  @moduledoc """
  Wraps a field dropped with no form around it, and binds a field dropped inside one.

  Prevention rather than a report, because "this field is not inside a form" is a mistake with
  exactly one sensible repair and no reason to make the author read about it. One template rewrite,
  so one `:insert` op and one undo step.

  It is deliberately NOT a `MishkaCmsCore.Runtime.PageBuilder.Containment` refusal. Building a form
  top-down — three fields first, wrapper after — is an ordinary gesture, and refusing it turns the
  intermediate state of a legal workflow into an error message. `Containment` refuses only the
  nesting HTML itself forbids.

  ## What gets a binding

  A component the kit calls a field — `MishkaCmsCore.Runtime.PageBuilder.Fields.field_node?/2`, the
  editor's one answer to that, which reads the kit's own declaration first — is bound where it
  stands. Anything else is asked of the controls UNDER it, because a template is one field rather
  than one node: `el-checkbox` is a `<label>` over a hidden input and a checkbox, `el-radio-group` a
  `<fieldset>` over its options, and in both the head carries no value at all while every control
  beneath it answers to one name.

  Asking only the head left those two never bound. They kept their literal `name`, so the browser
  posted `agree` at the event's TOP level while `MishkaCmsCore.Runtime.PageForm.scoped/2` reads only
  `params["contact"]` — the consent tick was dropped from every submission, the spec claimed a key no
  input carried, and nothing in the audit rail said so.

  One name is one field, and several names are several fields the drop has no business choosing
  between, so a head over controls with different names is left exactly as it arrived. So is a
  template that brings a form of its own, and a head already carrying a binding.

  The attribute the binding is written on is the kit's, not this module's: `Fields.binding_attr/1`
  names the component's `Phoenix.HTML.FormField` attribute whatever the kit called it, and a kit that
  takes no such struct gets the `Fields.pair_attrs/1` pair instead — `name={f[:email].name}` and
  `value={f[:email].value}`. A raw `<input name="field">` from the Elements library takes the same
  pair, which is what turns a palette template that has to render standalone into a real field on
  the page.

  ## A value the author wrote is kept

  `value="one"` on a radio, `value="true"` on a checkbox and the `value="false"` on the hidden input
  beside it are the option's identity, not the box the visitor types in. Binding them would give
  every option in a group the form's own value and leave the submission with nothing to tell them
  apart, so a control that already carries a written value takes the name binding alone. A palette
  card's seeded blank is not a value and is superseded as it always was.

  ## Where the key comes from

  `MishkaCmsCore.Runtime.PageBuilder.Fields.field_label/2` — the author's own words where there are
  any, asked of the kit's own attributes rather than of Phoenix's spelling — minted through
  `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming.field_key/2` so it is legal and unique inside
  the form it is joining. Two email fields in one form are `email` and `email_2`, never one key with
  two inputs writing over each other.

  What is already taken is `MishkaCmsCore.Runtime.PageBuilder.PageForms.names/2`, the text half:
  every drop used to intern an atom per name already in the form, from markup an author is still
  typing, only for the minting to compare them as strings.

  ## Where a field lands

  `place/3` is what every placement asks. A field joins the form it is dropped in or against, the
  form's own top or bottom edge included; anywhere else it starts a new form that comes with the
  styled Send button. A field never lands after its form's first Send button: a spot past it is moved
  in front of it (`landing/4`), wherever in the form the Send button sits. A kit wrapper that hands
  its form to its content arrives wired on a Page (`wiring/4`).

  ## Moving a field between forms

  `unit/3` is the whole field a node belongs to (a checkbox's label with its hidden twin, a radio
  group), `move_ops/3` moves it to another form or into a new one and `merge_ops/3` moves every field
  of a form into another. A form left with no fields is removed in the same step.

  See `MishkaCmsCore.Runtime.PageBuilder.PageForms` for what makes a node a form in the first place.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Containment
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Section
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @seed "form"

  @send_button "el-submit"

  @let :f

  # Stacks the field and its Send button, as the Form element does.
  @form_class "space-y-4"

  # HTML's own wrappers of one field: a label around its control, a fieldset around its options.
  @field_wrappers ~w(label fieldset)

  @new "new"

  # How long a bound field waits after the last keystroke before it is checked, in ms.
  @debounce "300"

  # What a Send button the editor puts in a form says while the form is being sent.
  @sending "Sending…"

  # Controls nobody types into.
  @untyped ~w(checkbox radio hidden file)

  @typedoc "What a placement did about forms."
  @type outcome :: :none | {:joined, String.t() | nil} | :started | :wired

  @doc "What the author is told after a placement, or `nil` when there is nothing to say."
  @spec told(outcome()) :: String.t() | nil
  def told({:joined, name}), do: gettext("Added it to %{form}.", form: phrase(name))

  def told(:started),
    do:
      gettext(
        "Started a new form with a Send button. To add it to another one instead, choose it under In form in the Inspector."
      )

  def told(_outcome), do: nil

  defp joined_told(name, true),
    do: gettext("Added it to %{form}. The empty form was removed.", form: phrase(name))

  defp joined_told(name, false), do: told({:joined, name})

  defp started_told(true),
    do:
      gettext(
        "Started a new form with a Send button. To add it to another one instead, choose it under In form in the Inspector. The empty form was removed."
      )

  defp started_told(false), do: told(:started)

  defp own_address, do: gettext("It sends to its own web address, so it stays as it is.")

  @doc ~S"""
  A form as a sentence names it: "Form 2", "the Contact form", or "the form" when it has no name.
  """
  @spec phrase(String.t() | nil) :: String.t()
  def phrase(nil), do: gettext("the form")
  def phrase(name) when is_binary(name), do: name |> numbered?() |> phrased(name)

  defp numbered?(name) do
    case Regex.run(~r/\d+/, name) do
      [number] -> name == Naming.numbered_name(number)
      nil -> false
    end
  end

  defp phrased(true, name), do: name
  defp phrased(false, name), do: gettext("the %{name} form", name: name)

  @doc "A working form's people name (`Naming.people_name/1` of its seed), or `nil`."
  @spec form_name(Node.t() | nil) :: String.t() | nil
  def form_name(%Node{} = node),
    do: node |> PageForms.form?() |> working_seed(node) |> Naming.people_name()

  def form_name(_node), do: nil

  defp working_seed(true, node), do: PageForms.param_name(node)
  defp working_seed(false, _node), do: nil

  @doc "Every working form in `tree` a field can join, as `{node id, people name}` in document order."
  @spec forms(Tree.t()) :: [{String.t(), String.t()}]
  def forms(%Tree{} = tree) do
    for node <- Tree.walk(tree),
        name = form_name(node),
        is_binary(name),
        PageForms.let_var(node) != nil,
        do: {node.id, name}
  end

  @doc """
  The styled Send button a form is given: the Elements palette's `el-submit`, read by id so every
  place that adds one inserts the same markup.
  """
  @spec send_button() :: String.t()
  def send_button, do: Elements.get(@send_button).template

  @doc """
  The ops that switch how the working form `form_id` sends, as one undo step, and the sentence the
  author is told.

    * `:typing` removes every Send button inside the form and records the choice on it
      (`PageForms.as_typed_attr/0`). Its `phx-submit` stays, so Enter never reloads the page. A
      form `as_typed_offered?/2` refuses is refused with a sentence.
    * `:send` removes the record and, when no Send button is left, adds the styled one
      (`send_button/0`) at the end of the form's content. The form stays selected.
  """
  @spec how_ops(map(), String.t(), :typing | :send) ::
          {:ok, [map()], String.t()} | {:error, String.t()}
  def how_ops(session, form_id, how) when how in [:typing, :send] do
    case Tree.get(session.tree, form_id) do
      %Node{} = form -> form |> PageForms.form?() |> how_for(session, form, how)
      nil -> {:error, gettext("That form is no longer on the page.")}
    end
  end

  defp how_for(false, _session, _form, _how),
    do: {:error, gettext("This form does not work yet.")}

  defp how_for(true, session, form, :typing),
    do: session |> as_typed_offered?(form) |> typed(session, form)

  defp how_for(true, session, form, :send) do
    {nodes, roles, rules} = sending(session.tree, form, session.components)

    # The record goes last: an op that changes an attribute keeps the selection, so the form stays
    # selected and its Form panel open instead of following the Send button just added.
    {:ok,
     send_added(first_send(nodes, roles, rules), session.tree, form) ++
       [%{kind: :delete_attr, node_id: form.id, name: PageForms.as_typed_attr()}],
     gettext("It now sends when they press Send.")}
  end

  defp typed(false, _session, _form),
    do: {:error, gettext("This form cannot work as they type.")}

  defp typed(true, session, form) do
    {nodes, roles, rules} = sending(session.tree, form, session.components)

    removed =
      nodes
      |> Enum.filter(&Fields.submit_node?(&1, roles, rules))
      |> outermost(session.tree)
      |> Enum.map(&%{kind: :delete, node_id: &1.id})

    {:ok,
     removed ++
       [
         %{
           kind: :set_attr,
           node_id: form.id,
           name: PageForms.as_typed_attr(),
           value: "",
           value_kind: :boolean
         }
       ], gettext("It now works as they type, with no Send button.")}
  end

  @doc """
  Whether the form `form` can be made to work as they type: a working form on a Page that passes
  the attribute recording it (`PageForms.as_typed_attr/0`) on to what it renders. The Form panel's
  How it works, the audit's "Make it work as they type" and `how_ops/3` all ask this.
  """
  @spec as_typed_offered?(map(), Node.t() | nil) :: boolean()
  def as_typed_offered?(session, %Node{} = form),
    do:
      page_forms?(session) and PageForms.form?(form) and
        Fields.takes?(form, PageForms.as_typed_attr(), session.components)

  def as_typed_offered?(_session, _form), do: false

  defp send_added(nil, tree, form),
    do: [
      %{
        kind: :insert,
        template: send_button(),
        parent_id: form.id,
        index: content_end(tree, form)
      }
    ]

  defp send_added(_send, _tree, _form), do: []

  @doc """
  The template to insert, and whether a form was put around it.

  `parent_id` is where the drop is about to land, so the question "is there a form here" is asked of
  the page rather than of the template being dropped. A form put around a field comes with the
  styled Send button.
  """
  @spec wrap(String.t(), map(), String.t() | nil) :: {String.t(), boolean()}
  def wrap(template, session, parent_id) do
    with true <- page_forms?(session),
         {:ok, tree} <- Tree.parse(template),
         %Node{} = head <- head(tree),
         [_bound | _rest] = controls <- controls(tree, head, session.components),
         nil <- ancestor_form(session, parent_id) do
      {wrapped(tree, head, controls, session), true}
    else
      _leave_alone -> {bind(template, session, parent_id), false}
    end
  end

  @doc """
  The template to insert, the spot it lands in and what was done about forms.

  `params` carries `"parent_id"` and `"index"`, and `"anchor_id"`/`"anchor_before"` when the drop
  was aimed beside a node. On a Page a field joins the form it lands in or is dropped against (the
  answer's params then name the spot inside that form), and anywhere else it starts a new form with
  a Send button; a kit wrapper that hands its form to its content arrives wired, unless it already
  names its own `phx-submit`. Everywhere else a field is only bound to a form the author wrote
  around it.
  """
  @spec place(String.t(), map(), map()) :: {String.t(), map(), outcome()}
  def place(template, session, params) do
    with true <- page_forms?(session),
         {:ok, tree} <- Tree.parse(template),
         %Node{} = head <- head(tree) do
      arriving(template, tree, head, session, params)
    else
      _not_on_a_page -> {bind(template, session, parent_param(params)), params, :none}
    end
  end

  defp arriving(template, tree, head, session, params) do
    case controls(tree, head, session.components) do
      [] -> unfielded(template, tree, head, session, params)
      controls -> fielded(template, tree, head, controls, session, params)
    end
  end

  defp fielded(template, tree, head, controls, session, params) do
    case host(session, params, head, tree) do
      {form, spot} ->
        {joined(template, tree, controls, form, session), Map.merge(params, spot),
         {:joined, form_name(form)}}

      nil ->
        {wrapped(tree, head, controls, session), params, :started}
    end
  end

  defp unfielded(template, tree, head, session, params) do
    case lending?(head, session.components) do
      true -> {wired(template, tree, head, session), params, :wired}
      false -> {sent_into_form(template, tree, head, session, params), params, :none}
    end
  end

  # A Send button dropped inside a form says "Sending…" while it sends.
  defp sent_into_form(template, tree, head, session, params) do
    with %Node{} <- ancestor_form(session, parent_param(params)),
         [_first | _rest] = ops <- sending_ops(subtree(tree, head), session.components) do
      ops |> Enum.reduce(tree, &applied(&2, &1)) |> Serializer.serialize()
    else
      _nothing_to_say -> template
    end
  end

  # Each Send button among `nodes` that passes `phx-disable-with` on and names none of its own.
  defp sending_ops(nodes, components) do
    roles = Fields.roles(nodes, components)
    rules = Fields.submit_rules(roles, components)

    for node <- nodes,
        Fields.submit_node?(node, roles, rules),
        Node.attr(node, "phx-disable-with") == nil,
        Fields.takes?(node, "phx-disable-with", components),
        do: attr_op(node.id, {"phx-disable-with", {:string, @sending}})
  end

  # A wrapper that names its own `phx-submit` or `action` is a developer's and arrives as it came.
  defp lending?(%Node{kind: :component} = head, components),
    do:
      not PageForms.form?(head) and Node.attr_text(head, "phx-submit") in [nil, ""] and
        wirable?(head, components)

  defp lending?(_head, _components), do: false

  defp wired(template, tree, head, session) do
    case wiring(session.tree, head, session.components, within: tree) do
      {:ok, ops} -> ops |> Enum.reduce(tree, &applied(&2, &1)) |> Serializer.serialize()
      {:error, _refused} -> template
    end
  end

  @doc """
  Whether a template being dragged in is a field: its head is one, or the controls under it answer
  to one name.
  """
  @spec arriving_field?(Tree.t(), Node.t(), [map()]) :: boolean()
  def arriving_field?(tree, %Node{} = head, components),
    do: controls(tree, head, components) != []

  def arriving_field?(_tree, _head, _components), do: false

  @doc "Whether this node in the document is part of a field (`unit/3` answers for it)."
  @spec field?(Tree.t(), Node.t(), [map()]) :: boolean()
  def field?(tree, %Node{} = node, components), do: unit(tree, node, components) != nil
  def field?(_tree, _node, _components), do: false

  # ONLY A PAGE COMPILES A FORM. The wrapper `wrap/3` writes carries `for={assigns[:form_form]}`,
  # `phx-change="form-<token>-validate"` and `phx-submit="form-<token>-submit"`, and
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.build_page_forms/1` is the only compiler that
  # emits `__page_forms__/0` and those two handlers — the layout, error-page and component compilers
  # emit none of it. So on those three the "help" was markup bound to an assign nothing supplies and
  # events nothing handles, announced to the author as a form they now had.
  #
  # Public because the audit asks the same question of the same session:
  # `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormChecks` reported loose fields and unreached
  # forms on the three sections this refuses to build one on, and the Fix for a loose field came
  # back here and answered `:none` — a blocker nothing could clear. One gate, one answer.
  @doc """
  Whether this section's compiler emits `__page_forms__/0` — whether a form written here could ever
  reach a destination.

  Total: anything without a section is not a page.
  """
  @spec page_forms?(map()) :: boolean()
  def page_forms?(%{section: section}) when is_binary(section),
    do: Section.normalize(section) == "page"

  def page_forms?(_session), do: false

  # NOT gated: binding a field to a form the author wrote themselves is correct HEEx wherever they
  # wrote it, and the `else` branch of `wrap/3` still reaches it.
  @doc """
  The template with its field bound to the form it is landing in, or the template untouched.

  Untouched covers every case that is not a field joining a form: a block that brings its own form,
  a drop with no form above it, a field already carrying a binding, and a form whose `:let` variable
  is missing — binding to a variable the form does not bind would not compile.
  """
  @spec bind(String.t(), map(), String.t() | nil) :: String.t()
  def bind(template, session, parent_id) do
    with {:ok, tree} <- Tree.parse(template),
         %Node{} = head <- head(tree),
         [_first | _rest] = controls <- controls(tree, head, session.components),
         %Node{} = form <- ancestor_form(session, parent_id) do
      joined(template, tree, controls, form, session)
    else
      _leave_alone -> template
    end
  end

  defp joined(template, tree, [first | _rest] = controls, form, session) do
    with var when is_atom(var) and not is_nil(var) <- PageForms.let_var(form),
         nil <- PageForms.bound_key(first, var) do
      tree
      |> write(controls, var, taken(session.tree, form), session.components)
      |> Serializer.serialize()
    else
      _leave_alone -> template
    end
  end

  defp wrapped(tree, head, controls, session) do
    form = form_node(session)

    tree
    |> Tree.wrap(head.id, form)
    |> either(tree)
    |> sent(form.id)
    |> write(controls, @let, [], session.components)
    |> Serializer.serialize()
  end

  # The styled Send button, last inside the form.
  defp sent(tree, form_id), do: send_button() |> Tree.parse() |> sent_into(tree, form_id)

  defp sent_into({:ok, send}, tree, form_id) do
    case Tree.get(tree, form_id) do
      %Node{children: children} ->
        tree |> Tree.insert(send, form_id, length(children)) |> either(tree)

      nil ->
        tree
    end
  end

  defp sent_into(_unparsed, tree, _form_id), do: tree

  # NOT named after the field that asked for it. Wrapping an email field would give `email-form`, and
  # the form is not an email — a contact form whose first field is "Your name" would come out
  # `name-form`, which reads like a decision somebody made. `form`, `form_2`, `form_3` says what is
  # true: the editor does not know what this form is for, and the Form section of the Inspector is
  # where the author says.
  defp form_node(session) do
    Node.new(:component,
      tag: ".form",
      attrs:
        [
          {":let", {:expr, "#{@let}"}}
          | Naming.attrs(Naming.unique(session.tree, @seed), Naming.mint_token(session.tree))
        ] ++ [{"class", {:string, @form_class}}]
    )
  end

  @doc """
  The ops that make an idle form-lending node (`Fields.hands_form?/2`) a working form: `:let`, the
  five names with a fresh token, and a binding for every field inside it, ready for
  `MishkaCmsCore.Runtime.PageBuilder.EditorSession.apply_ops/4`.

  `tree` is the page the names must be unique in. A seed the node already carries in `as` is kept.
  A `phx-submit` the page's code already answers (`:events`) is the developer's: then only `:let`,
  `for` and `as` are written, and its fields keep the names that code reads. A form that posts to
  its own `action` is a developer's and is refused.

  ## Options

    * `:within` - the tree `node` sits in, when it is not `tree` (a template on its way in).
    * `:events` - the page's Events-tab entries. Defaults to `[]`.
    * `:seed` - the name to start from when the node carries no `as`. Defaults to `"form"`.
    * `:keep_id` - `true` keeps an `id` the node already has. Defaults to `false`.
  """
  @spec wiring(Tree.t(), Node.t(), [map()], keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def wiring(tree, %Node{} = node, components, opts \\ []) do
    cond do
      PageForms.form?(node) ->
        {:error, gettext("It is already a working form.")}

      Node.attr(node, "action") != nil ->
        {:error, own_address()}

      not Fields.hands_form?(node, components) ->
        {:error, gettext("Replace it with Form from Blocks › Forms.")}

      true ->
        {:ok, wiring_ops(tree, Keyword.get(opts, :within, tree), node, components, opts)}
    end
  end

  defp wiring_ops(tree, within, node, components, opts) do
    var = PageForms.let_var(node) || @let
    seed = Naming.unique(tree, PageForms.param_name(node) || Keyword.get(opts, :seed) || @seed)

    mine? =
      PageForms.answered?(Keyword.get(opts, :events, []), Node.attr_text(node, "phx-submit"))

    names =
      node
      |> Naming.names_for(seed, Naming.mint_token(tree))
      |> kept_handler(mine?)
      |> kept_id(Keyword.get(opts, :keep_id, false) and Node.attr_text(node, "id") != nil)

    let_op(node, var) ++
      Enum.map(names, &attr_op(node.id, &1)) ++
      bindings(mine?, within, node, var, components) ++ files_ops(within, node, components)
  end

  # A developer's own handler reads its fields under the names they already have, and its Send
  # buttons stay as they are; any other form's fields are bound and its Send buttons say "Sending…".
  defp bindings(true, _within, _node, _var, _components), do: []

  defp bindings(false, within, node, var, components),
    do:
      inside_bindings(within, node, var, components) ++
        sending_ops(descendants(within, node), components)

  @doc """
  The ops that replace the raw `<form>` `node_id` with a working `<.form>` in one undo step: the
  same attributes and children, then `wiring/4`. The form keeps its own `id`, so what already points
  at it still does. A form that posts to its own `action` is a developer's and is refused.

  ## Options

    * `:events` - the page's Events-tab entries. Defaults to `[]`.
  """
  @spec replace_ops(map(), String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def replace_ops(session, node_id, opts \\ []) do
    case Tree.get(session.tree, node_id) do
      %Node{kind: :tag, tag: "form"} = node ->
        node |> Node.attr("action") |> replaced(session, node, opts)

      _other ->
        {:error, gettext("Only a plain HTML form can be replaced.")}
    end
  end

  defp replaced(nil, session, node, opts) do
    scratch = Tree.subtree(session.tree, node.id)
    form = %{node | kind: :component, tag: ".form", parent_id: nil}
    scratch = %{scratch | nodes: Map.put(scratch.nodes, node.id, form)}

    wired =
      wiring(session.tree, form, session.components,
        within: scratch,
        events: Keyword.get(opts, :events, []),
        seed: node |> Node.attr_text("id") |> without_form_suffix(),
        keep_id: true
      )

    case wired do
      {:ok, ops} ->
        {:ok,
         swap(
           session.tree,
           node,
           ops |> Enum.reduce(scratch, &applied(&2, &1)) |> Serializer.serialize()
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replaced(_action, _session, _node, _opts), do: {:error, own_address()}

  # Out first, so the form's own ids and its children's are free for the one that takes its place.
  defp swap(tree, node, template),
    do: [
      %{kind: :delete, node_id: node.id},
      %{
        kind: :insert,
        template: template,
        parent_id: node.parent_id || "root",
        index: Tree.index_of(tree, node.id) || 0
      }
    ]

  defp without_form_suffix(nil), do: nil
  defp without_form_suffix(id), do: String.replace_suffix(id, "-form", "")

  @doc """
  The op that turns `multipart` on for `form` when a file field sits inside it in `tree`, so the
  files chosen there are sent with it; `[]` when there is none, the form already carries it, or it
  does not pass `multipart` on.
  """
  @spec files_ops(Tree.t(), Node.t(), [map()]) :: [map()]
  def files_ops(tree, %Node{kind: :component} = form, components) do
    case Node.attr(form, "multipart") == nil and Fields.takes?(form, "multipart", components) and
           Inspector.holds_file_field?(tree, form, components) do
      true -> [attr_op(form.id, {"multipart", {:expr, "true"}})]
      false -> []
    end
  end

  def files_ops(_tree, _form, _components), do: []

  @doc """
  `tree` with `multipart` turned on (`files_ops/3`) for every form the node `node_id` sits in, is or
  holds: what a node put or moved there asks of the form it lands in.
  """
  @spec filed(Tree.t(), String.t() | nil, [map()]) :: Tree.t()
  def filed(tree, node_id, components) do
    case Tree.get(tree, node_id) do
      %Node{} = node ->
        tree
        |> touched_forms(node, components)
        |> Enum.flat_map(&files_ops(tree, &1, components))
        |> Enum.reduce(tree, &applied(&2, &1))

      nil ->
        tree
    end
  end

  defp touched_forms(tree, node, components) do
    inside = [node | descendants(tree, node)]
    roles = Fields.roles(inside, components)

    [owning(tree, node, components) | Enum.filter(inside, &Fields.form_node?(&1, roles))]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Whether Make it a working form can make the idle form `node` one: it posts to no web address of
  its own, and it hands its form to its content (`wiring/4`) or is a plain HTML form
  (`replace_ops/3`).
  """
  @spec wirable?(Node.t() | nil, [map()]) :: boolean()
  def wirable?(%Node{} = node, components),
    do:
      Node.attr(node, "action") == nil and
        (Fields.hands_form?(node, components) or replaceable?(node))

  def wirable?(_node, _components), do: false

  @doc "Whether `replace_ops/3` can make the raw `<form>` `node` a working form."
  @spec replaceable?(Node.t()) :: boolean()
  def replaceable?(%Node{kind: :tag, tag: "form"} = node), do: Node.attr(node, "action") == nil
  def replaceable?(_node), do: false

  defp let_op(node, var) do
    case PageForms.let_var(node) do
      nil -> [attr_op(node.id, {":let", {:expr, "#{var}"}})]
      _bound -> []
    end
  end

  # A developer's own handler keeps the event names it answers to.
  defp kept_handler(names, true),
    do: Enum.filter(names, fn {name, _value} -> name in ~w(as for) end)

  defp kept_handler(names, false), do: names

  # An id the form already has stays, when the caller asks for it.
  defp kept_id(names, true), do: Enum.reject(names, fn {name, _value} -> name == "id" end)
  defp kept_id(names, false), do: names

  defp inside_bindings(tree, node, var, components) do
    nodes = descendants(tree, node)
    roles = Fields.roles(nodes, components)
    taken = for n <- nodes, key = PageForms.bound_key(n, var), !is_nil(key), do: to_string(key)

    nodes
    |> Enum.filter(&(Fields.field_node?(&1, roles) and PageForms.bound_key(&1, var) == nil))
    |> Enum.chunk_by(&group_name(&1, components))
    |> regrouped(components)
    |> Enum.flat_map_reduce(taken, fn [first | _rest] = group, taken ->
      key = Naming.field_key(label_of(first, components), taken)
      {Enum.flat_map(group, &binding_ops(&1, components, var, key)), [key | taken]}
    end)
    |> elem(0)
  end

  # Controls answering to one literal name are one field, wherever they sit.
  defp regrouped(chunks, components) do
    chunks
    |> Enum.group_by(&(&1 |> hd() |> group_name(components)))
    |> then(fn by_name ->
      chunks
      |> Enum.map(&group_name(hd(&1), components))
      |> Enum.uniq()
      |> Enum.map(&List.flatten(Map.fetch!(by_name, &1)))
    end)
  end

  defp group_name(node, components) do
    case Node.literal(node, own_name_attr(node, components)) do
      nil -> {:node, node.id}
      name -> {:name, name}
    end
  end

  defp own_name_attr(%Node{kind: :component} = node, components) do
    case node |> Fields.entry(components) |> entry_name_attr() do
      nil -> "name"
      attr -> attr
    end
  end

  defp own_name_attr(_node, _components), do: "name"

  defp entry_name_attr(nil), do: nil
  defp entry_name_attr(entry), do: entry |> Fields.pair_attrs() |> elem(0)

  defp binding_ops(node, components, var, key),
    do: node |> binding(components, var, key) |> Enum.map(&binding_op(node.id, &1))

  defp binding_op(id, {:set, name, value}), do: attr_op(id, {name, value})
  defp binding_op(id, {:drop, name}), do: %{kind: :delete_attr, node_id: id, name: name}

  defp attr_op(id, {name, {kind, value}}),
    do: %{kind: :set_attr, node_id: id, name: name, value: value, value_kind: kind}

  defp applied(tree, %{kind: :set_attr, node_id: id, name: name, value: value, value_kind: kind}),
    do: tree |> Tree.set_attr(id, name, {kind, value}) |> either(tree)

  defp applied(tree, %{kind: :delete_attr, node_id: id, name: name}),
    do: tree |> Tree.delete_attr(id, name) |> either(tree)

  defp write(tree, [first | _rest] = controls, var, taken, components) do
    key = Naming.field_key(label_of(first, components), taken)

    Enum.reduce(controls, tree, &rebound(&2, &1, var, key, components))
  end

  # The key a control is already bound to under any form's variable, else the author's own word.
  defp label_of(node, components) do
    case PageForms.bound_var(node) do
      nil -> Fields.field_label(node, components)
      var -> node |> PageForms.bound_key(var) |> key_or_label(node, components)
    end
  end

  defp key_or_label(nil, node, components), do: Fields.field_label(node, components)
  defp key_or_label(key, _node, _components), do: Atom.to_string(key)

  defp rebound(tree, node, var, key, components) do
    node
    |> binding(components, var, key)
    |> Enum.reduce(tree, &set(&2, node.id, &1))
  end

  @doc """
  How binding `node` to `key` changes it: what to set, and what that supersedes.

  `{:set, name, source}` and `{:drop, name}`, in the order they must be applied. The caller renders
  them in whatever shape it applies ops in — this module writes straight to a tree, the audit's Fix
  builds `MishkaCmsCore.Runtime.PageBuilder.Op` structs — but WHICH attributes move is decided once,
  here, because it was decided twice and the two answers drifted.

  ## Why anything is dropped

  A palette card is seeded `name=""` and `value=""` so it renders standing alone on a canvas, and a
  kit derives both from the form field with `assign_new/3`, which fills only an ABSENT key. Leave the
  empty pair beside the binding that replaces it and the empty pair wins: the input renders `name=""`
  and submits nothing at all, while the page validates a key no input carries.

  ## Why the value is sometimes left

  `node` rather than its palette entry, because the entry cannot answer this: a control the author
  already gave a written value is a radio option, a checkbox's `true` or the hidden `false` beside
  it, and the value there is the option's identity. It keeps it and takes the name binding alone.
  """
  @spec binding(Node.t(), [map()], atom(), atom() | String.t()) ::
          [{:set, String.t(), {:expr | :string, String.t()}} | {:drop, String.t()}]
  def binding(node, components, var, key),
    do:
      node
      |> Fields.entry(components)
      |> attr_names()
      |> written(var, key, Fields.written_value?(node))
      |> Kernel.++(debounced(node, components))

  # A field the editor binds is checked 300 ms after the visitor stops typing, where it forwards
  # `phx-debounce` and names no timing of its own. A box, a hidden value or a file has nothing typed.
  defp debounced(node, components) do
    case Node.attr(node, "phx-debounce") == nil and typed?(node, components) and
           Fields.takes?(node, "phx-debounce", components) do
      true -> [{:set, "phx-debounce", {:string, @debounce}}]
      false -> []
    end
  end

  defp typed?(%Node{kind: :tag, tag: "input"} = node, _components),
    do: typed_word?(Node.attr_text(node, "type"))

  # A component's own written `type`, else the one its markup writes on the `<input>` it passes its
  # attributes to. A type that cannot be read counts as typed.
  defp typed?(%Node{kind: :component} = node, components) do
    case PageForms.type_word(Node.attr_text(node, "type")) do
      nil -> node |> Fields.entry(components) |> Fields.forwarded_type() |> typed_word?()
      word -> typed_word?(word)
    end
  end

  defp typed?(_node, _components), do: true

  defp typed_word?(type), do: PageForms.type_word(type) not in @untyped

  # A RAW `<input>` HAS HTML'S OWN TWO NAMES and no palette entry to read them off. A component's
  # are the kit's, and `Fields.bindings/1` answers `nil` for one the kit does not have rather than
  # guessing Phoenix's spelling — so nothing is written onto an attribute that is not there, and
  # nothing that is there is left behind. Both halves come back from one call because they are one
  # decision, and asking twice rebuilt the declaration and re-parsed the component's markup twice.
  defp attr_names(nil), do: {nil, {"name", "value"}}
  defp attr_names(entry), do: Fields.bindings(entry)

  defp written({nil, {name, value}}, var, key, false)
       when is_binary(name) and is_binary(value),
       do: [
         {:set, name, {:expr, "#{var}[:#{key}].name"}},
         {:set, value, {:expr, "#{var}[:#{key}].value"}}
       ]

  defp written({nil, {name, _value}}, var, key, _own) when is_binary(name),
    do: [{:set, name, {:expr, "#{var}[:#{key}].name"}}]

  defp written({nil, _pair}, _var, _key, _own), do: []

  defp written({attr, pair}, var, key, _own),
    do: [{:set, attr, {:expr, "#{var}[:#{key}]"}} | drops(pair)]

  defp drops({name, value}), do: [name, value] |> Enum.reject(&is_nil/1) |> Enum.map(&{:drop, &1})

  defp set(tree, id, {:set, name, value}) do
    tree
    |> Tree.set_attr(id, name, value)
    |> either(tree)
  end

  defp set(tree, id, {:drop, name}) do
    tree
    |> Tree.delete_attr(id, name)
    |> either(tree)
  end

  defp either({:ok, tree}, _previous), do: tree
  defp either({:error, _refused}, previous), do: previous

  defp head(tree) do
    tree.roots
    |> Enum.map(&Tree.get(tree, &1))
    |> Enum.find(&element?/1)
  end

  defp element?(%Node{kind: kind}), do: kind in [:tag, :component]
  defp element?(_node), do: false

  # A COMPONENT IS BOUND WHERE IT STANDS; anything else is asked of the controls under it, because
  # `el-checkbox`'s head is a `<label>` and `el-radio-group`'s is a `<fieldset>` — neither carries a
  # value, and asking only the head left both of them posting their literal name at the event's top
  # level, outside the scope the form reads.
  defp controls(_tree, %Node{kind: :component} = head, components),
    do: head |> Fields.field_node?(Fields.roles([head], components)) |> declared(head)

  defp controls(tree, head, components), do: tree |> subtree(head) |> loose(components)

  defp declared(true, head), do: [head]
  defp declared(false, _head), do: []

  defp subtree(tree, head) do
    [head | tree |> Tree.descendant_ids(head.id) |> Enum.map(&Tree.get(tree, &1))]
    |> Enum.reject(&is_nil/1)
  end

  # A template that brings a form of its own brings its fields' scope with it, so nothing in it is
  # loose and nothing in it is bound to the form outside.
  defp loose(nodes, components) do
    roles = Fields.roles(nodes, components)

    nodes
    |> Enum.any?(&Fields.form_node?(&1, roles))
    |> outside(nodes)
  end

  defp outside(true, _nodes), do: []
  defp outside(false, nodes), do: nodes |> Enum.filter(&control_node?/1) |> one_field()

  defp control_node?(%Node{kind: :tag} = node), do: Fields.field_node?(node)
  defp control_node?(_node), do: false

  # ONE NAME IS ONE FIELD: the hidden `false` and the checkbox beside it, or every option in a radio
  # group, are one value under one key. Controls answering to DIFFERENT names are several fields, and
  # which of them the author meant is not the drop's to guess.
  defp one_field([]), do: []
  defp one_field([only]), do: [only]

  defp one_field([first | _rest] = controls),
    do: sharing(controls, Node.literal(first, "name"))

  defp sharing(_controls, nil), do: []

  defp sharing(controls, name),
    do: controls |> Enum.all?(&(Node.literal(&1, "name") == name)) |> shared(controls)

  defp shared(true, controls), do: controls
  defp shared(false, _controls), do: []

  # A form the author placed themselves counts even while it is still missing the attributes that
  # make it work: wrapping a field in a second form because the first one has no `for=` yet would
  # nest two forms, which browsers resolve by dropping the inner one and everything after it.
  defp ancestor_form(session, parent_id) do
    chain = chain(session.tree, parent_id)
    roles = Fields.roles(chain, session.components)

    Enum.find(chain, &Fields.form_node?(&1, roles))
  end

  defp chain(_tree, nil), do: []
  defp chain(_tree, :root), do: []
  defp chain(tree, id), do: tree |> Tree.get(id) |> lineage(tree, id)

  defp lineage(nil, _tree, _id), do: []
  defp lineage(node, tree, id), do: [node | Tree.ancestors(tree, id)]

  defp taken(tree, form), do: PageForms.names(tree, form)

  # The form a field joins, and the spot it lands in there. `nil` when it joins none.
  defp host(session, params, head, dragged_tree),
    do: session |> hosting(params) |> hosted(session, params, head, dragged_tree)

  # The form the spot is inside (`:inside`), else the form it was dropped against (`:against`).
  defp hosting(session, params) do
    case ancestor_form(session, parent_param(params)) do
      %Node{} = form -> {form, :inside}
      nil -> against(session, params)
    end
  end

  defp against(session, %{"anchor_id" => id}) when is_binary(id) do
    with %Node{} = anchor <- Tree.get(session.tree, id),
         true <- Fields.form_node?(anchor, Fields.roles([anchor], session.components)) do
      {anchor, :against}
    else
      _not_a_form -> nil
    end
  end

  defp against(_session, _params), do: nil

  # The spot `head` lands in inside the hosting form.
  defp hosted(nil, _session, _params, _head, _dragged_tree), do: nil

  defp hosted({form, :inside}, session, params, head, dragged_tree),
    do: {form, settled(session, form, parent_param(params), params["index"], head, dragged_tree)}

  defp hosted({form, :against}, session, params, head, dragged_tree),
    do: {form, edge(session, form, params["anchor_before"], head, dragged_tree)}

  # The top edge lands first inside the form, the bottom edge where the form's end is.
  defp edge(_session, form, true, _head, _dragged_tree),
    do: %{"parent_id" => form.id, "index" => 0}

  defp edge(session, form, _after, head, dragged_tree) do
    session.tree
    |> landing(form, session.components, dragged: head, dragged_tree: dragged_tree)
    |> spot()
  end

  # A spot past the form's first Send button moves in front of it; any other spot is kept.
  defp settled(session, form, parent, index, head, dragged_tree) do
    {nodes, roles, rules} = sending(session.tree, form, session.components)

    case first_send(nodes, roles, rules) do
      nil ->
        %{}

      send ->
        session.tree
        |> beyond_send?(form, send, parent, index, head)
        |> resettled(session, form, send, dragged: head, dragged_tree: dragged_tree)
    end
  end

  # A Send button in one of the form's own slots renders after the form's content wherever the slot
  # sits among its children, so only a spot inside that slot is beyond it.
  defp beyond_send?(tree, form, send, parent, index, dragged) do
    case send_path(tree, form, send) do
      [%Node{kind: :slot} = slot | _rest] ->
        parent == slot.id or Tree.descendant?(tree, slot.id, parent)

      _in_content ->
        past?(tree, send, parent, index, dragged)
    end
  end

  defp resettled(false, _session, _form, _send, _opts), do: %{}

  defp resettled(true, session, form, send, opts),
    do: session.tree |> before_send(form, send, session.components, opts) |> spot()

  defp spot({parent, index}), do: %{"parent_id" => parent, "index" => index}

  @doc """
  Where a field added at the end of `form` lands, as `{parent id, index}`: in front of the form's
  first Send button, wherever inside the form it sits, or at the end when there is none.

  A Send button inside one of the form's own slots (a kit wrapper's `<:actions>`) is outside the
  form's `:let`, so the field lands at the end of the form's content instead, after its last child
  that is not a slot.

  ## Options

    * `:dragged` - the node, or nodes, arriving, so a spot whose parent refuses any of them is
      passed over for the next one out.
    * `:dragged_tree` - the tree `:dragged` belongs to.
  """
  @spec landing(Tree.t(), Node.t(), [map()], keyword()) :: {String.t(), non_neg_integer()}
  def landing(tree, %Node{} = form, components, opts \\ []) do
    {nodes, roles, rules} = sending(tree, form, components)

    case first_send(nodes, roles, rules) do
      nil -> {form.id, length(form.children)}
      send -> before_send(tree, form, send, components, opts)
    end
  end

  defp sending(tree, form, components) do
    nodes = descendants(tree, form)
    roles = Fields.roles(nodes, components)

    {nodes, roles, Fields.submit_rules(roles, components)}
  end

  defp first_send(nodes, roles, rules),
    do: Enum.find(nodes, &Fields.submit_node?(&1, roles, rules))

  defp before_send(tree, form, send, components, opts) do
    case send_path(tree, form, send) do
      [%Node{kind: :slot} | _rest] ->
        {form.id, content_end(tree, form)}

      [outer | _rest] = path ->
        path
        |> Enum.reverse()
        |> Enum.find_value(
          {form.id, Tree.index_of(tree, outer.id)},
          &accepting(tree, &1, components, opts)
        )
    end
  end

  # After the form's last child that is not one of its slots: a slot renders where its component
  # puts it, whatever its place among the children.
  defp content_end(tree, form) do
    form.children
    |> Enum.with_index(1)
    |> Enum.reject(fn {id, _after} -> match?(%Node{kind: :slot}, Tree.get(tree, id)) end)
    |> List.last()
    |> after_content()
  end

  defp after_content({_id, at}), do: at
  defp after_content(nil), do: 0

  # The form's own children down to the Send button, outermost first.
  defp send_path(tree, form, send) do
    [send | Tree.ancestors(tree, send.id)]
    |> Enum.take_while(&(&1.id != form.id))
    |> Enum.reverse()
  end

  defp accepting(tree, candidate, components, opts) do
    at = {candidate.parent_id, Tree.index_of(tree, candidate.id)}

    case Keyword.get(opts, :dragged) do
      nil ->
        at

      dragged ->
        dragged
        |> List.wrap()
        |> Enum.all?(
          &(Containment.can_drop?(
              tree,
              &1,
              candidate.parent_id,
              [components: components] ++ Keyword.take(opts, [:dragged_tree])
            ) == :ok)
        )
        |> accepted(at)
    end
  end

  defp accepted(true, at), do: at
  defp accepted(false, _at), do: nil

  # Whether the spot `index` under `parent` comes after `send` in document order, counted as
  # `Tree.move/4` counts it: with the node being dragged already out of the row.
  defp past?(tree, send, parent, index, dragged) do
    order = tree |> Tree.walk() |> Enum.with_index(fn node, at -> {node.id, at} end) |> Map.new()
    siblings = tree |> Tree.child_ids(parent) |> List.delete(dragged.id)

    case point(tree, order, parent, siblings, clamped(index, siblings)) do
      nil -> false
      point -> Map.fetch!(order, send.id) <= point
    end
  end

  defp point(_tree, order, parent, _siblings, 0), do: Map.get(order, parent)

  defp point(tree, order, _parent, siblings, at) do
    previous = Enum.at(siblings, at - 1)

    Map.get(order, List.last([previous | Tree.descendant_ids(tree, previous)]))
  end

  defp clamped(index, siblings), do: index |> to_index(length(siblings)) |> min(length(siblings))

  defp to_index(index, _last) when is_integer(index) and index >= 0, do: index
  defp to_index(index, _last) when is_integer(index), do: 0

  defp to_index(index, last) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, _rest} -> to_index(parsed, last)
      :error -> last
    end
  end

  defp to_index(_index, last), do: last

  defp parent_param(params) do
    case params["parent_id"] do
      id when is_binary(id) and id not in ["", "root"] -> id
      _root -> nil
    end
  end

  @doc """
  What the canvas marks while a field is dragged: `forms` maps every form's node id to its people
  name, "" for a form that does not work yet, and `landings` holds each form's first Send button,
  which a field dropped at the form's end lands in front of (`landing/4`).

  `memo` is the roles already worked out, keyed by component name; the answer carries it grown.
  """
  @spec marks(Tree.t(), [map()], map()) :: {%{forms: map(), landings: MapSet.t()}, map()}
  def marks(%Tree{} = tree, components, memo \\ %{}) do
    nodes = Tree.walk(tree)
    roles = known_roles(nodes, components, Map.get(memo, :roles, %{}))
    rules = known_rules(roles, components, Map.get(memo, :rules, %{}))
    forms = Enum.filter(nodes, &Fields.form_node?(&1, roles))

    {%{
       forms: Map.new(forms, &{&1.id, form_name(&1) || ""}),
       landings:
         forms
         |> Enum.map(&landing_mark(tree, &1, roles, rules))
         |> Enum.reject(&is_nil/1)
         |> MapSet.new()
     }, %{roles: roles, rules: rules}}
  end

  defp known_roles(nodes, components, known) do
    nodes
    |> Enum.reject(&Map.has_key?(known, Node.component_name(&1)))
    |> Fields.roles(components)
    |> Map.merge(known)
  end

  defp known_rules(roles, components, known) do
    for({name, :submit} <- roles, not Map.has_key?(known, name), into: %{}, do: {name, :submit})
    |> Fields.submit_rules(components)
    |> Map.merge(known)
  end

  # The Send button itself: a slot it may sit in draws no element of its own.
  defp landing_mark(tree, form, roles, rules) do
    case first_send(descendants(tree, form), roles, rules) do
      nil -> nil
      send -> send.id
    end
  end

  @doc """
  The whole field `node` belongs to, or `nil` when it is not part of one: the smallest element
  holding every control of its key in its form (a checkbox's label with the hidden twin, a radio
  group), widened inside a form to the highest element below the form that holds nothing of another
  field (its label, its column), and outside every form only to a `<label>` or `<fieldset>` around
  it. Never the form itself, never a slot, and never anything that also holds another field or a
  Send button.
  """
  @spec unit(Tree.t(), Node.t(), [map()]) :: Node.t() | nil
  def unit(%Tree{} = tree, %Node{} = node, components) do
    form = owning(tree, node, components)
    scope = scope(tree, form, node)
    roles = Fields.roles(role_scope(tree, form, node, scope), components)

    ctx = %{
      tree: tree,
      form: form,
      var: let_of(form),
      roles: roles,
      rules: Fields.submit_rules(roles, components)
    }

    case identity_of(node, ctx) do
      nil ->
        nil

      id ->
        members = Enum.filter(scope, &(identity(&1, ctx) == id))

        node
        |> gathered(members, id, ctx)
        |> climbed(id, ctx)
    end
  end

  def unit(_tree, _node, _components), do: nil

  defp let_of(nil), do: nil
  defp let_of(form), do: PageForms.let_var(form)

  defp scope(tree, nil, node), do: [node | descendants(tree, node)]
  defp scope(tree, form, _node), do: descendants(tree, form)

  # A field outside every form may widen to a label beside other markup, so its roles are the page's.
  defp role_scope(tree, nil, _node, _scope), do: Tree.walk(tree)
  defp role_scope(_tree, _form, node, scope), do: [node | scope]

  defp descendants(tree, node) do
    tree
    |> Tree.descendant_ids(node.id)
    |> Enum.map(&Tree.get(tree, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc "The form `node` sits in, or `nil`."
  @spec form_of(Tree.t(), Node.t() | nil, [map()]) :: Node.t() | nil
  def form_of(%Tree{} = tree, %Node{} = node, components), do: owning(tree, node, components)
  def form_of(_tree, _node, _components), do: nil

  defp owning(tree, node, components) do
    ancestors = Tree.ancestors(tree, node.id)
    roles = Fields.roles(ancestors, components)

    Enum.find(ancestors, &Fields.form_node?(&1, roles))
  end

  # Which field a control is: the key it binds in its form, else its own literal name, else itself.
  defp identity(node, ctx) do
    case bound(node, ctx.var) do
      nil -> loose_identity(node, ctx.roles)
      key -> {:key, key}
    end
  end

  defp bound(_node, nil), do: nil
  defp bound(node, var), do: PageForms.bound_key(node, var)

  defp loose_identity(node, roles) do
    case Fields.field_node?(node, roles) do
      true -> {:name, Node.literal(node, "name") || node.id}
      false -> nil
    end
  end

  # A node's own identity, or the one identity every control under it shares.
  defp identity_of(node, ctx) do
    case holds_form?(node, ctx) do
      true -> nil
      false -> identity(node, ctx) || shared_identity(node, ctx)
    end
  end

  defp holds_form?(node, ctx),
    do: Enum.any?([node | descendants(ctx.tree, node)], &Fields.form_node?(&1, ctx.roles))

  defp shared_identity(node, ctx) do
    ctx.tree
    |> descendants(node)
    |> Enum.map(&identity(&1, ctx))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> single()
  end

  defp single([one]), do: one
  defp single(_none_or_several), do: nil

  defp gathered(node, members, id, ctx) do
    common = common(ctx.tree, [node | members])

    case inside?(common, ctx) and clean?(common, id, ctx) do
      true -> common
      false -> node
    end
  end

  defp climbed(unit, id, ctx) do
    parent = Tree.get(ctx.tree, unit.parent_id)

    climb_into(
      wrapper?(parent, ctx) and inside?(parent, ctx) and clean?(parent, id, ctx),
      parent,
      unit,
      id,
      ctx
    )
  end

  # Inside a form any element may hold the field, a slot never; outside every form only a label or
  # a fieldset does.
  defp wrapper?(%Node{kind: kind}, %{form: %Node{}}) when kind in [:tag, :component], do: true
  defp wrapper?(%Node{kind: :tag, tag: tag}, _ctx) when tag in @field_wrappers, do: true
  defp wrapper?(_parent, _ctx), do: false

  defp climb_into(true, parent, _unit, id, ctx), do: climbed(parent, id, ctx)
  defp climb_into(false, _parent, unit, _id, _ctx), do: unit

  defp common(tree, nodes) do
    nodes
    |> Enum.map(&Tree.path(tree, &1.id))
    |> Enum.reduce(&shared_prefix/2)
    |> List.last()
  end

  defp shared_prefix(path, acc),
    do:
      path
      |> Enum.zip(acc)
      |> Enum.take_while(fn {a, b} -> a.id == b.id end)
      |> Enum.map(&elem(&1, 0))

  defp inside?(nil, _ctx), do: false
  defp inside?(_node, %{form: nil}), do: true

  defp inside?(node, %{tree: tree, form: form}),
    do: node.id != form.id and Tree.descendant?(tree, form.id, node.id)

  defp clean?(node, id, ctx) do
    Enum.all?([node | descendants(ctx.tree, node)], fn part ->
      identity(part, ctx) in [nil, id] and not Fields.submit_node?(part, ctx.roles, ctx.rules) and
        not Fields.form_node?(part, ctx.roles)
    end)
  end

  @doc """
  Every field of `form` as its `unit/3`, outermost first, in document order.
  """
  @spec units(Tree.t(), Node.t(), [map()]) :: [Node.t()]
  def units(%Tree{} = tree, %Node{} = form, components) do
    nodes = descendants(tree, form)
    ctx = %{roles: Fields.roles(nodes, components), var: PageForms.let_var(form)}

    nodes
    |> Enum.filter(&(identity(&1, ctx) != nil))
    |> Enum.map(&unit(tree, &1, components))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> outermost(tree)
  end

  defp outermost(units, tree) do
    ids = MapSet.new(units, & &1.id)

    Enum.reject(units, fn unit ->
      tree |> Tree.ancestors(unit.id) |> Enum.any?(&MapSet.member?(ids, &1.id))
    end)
  end

  @doc "The `target` that asks `move_ops/3` for a new form."
  @spec new_target() :: String.t()
  def new_target, do: @new

  @doc """
  The ops that move the field `node_id` belongs to (`unit/3`) into another form, as one undo step,
  and the sentence the author is told.

  `target` is a working form's node id, or `new_target/0` for a new form with a Send button placed
  after the form the field leaves. Every control of the field is bound to the form it joins, under a
  key that form is not using. A form left with no fields is removed in the same step.
  """
  @spec move_ops(map(), String.t(), String.t()) ::
          {:ok, [map()], String.t()} | {:error, String.t()}
  def move_ops(session, node_id, target) do
    with {:ok, unit} <- unit_of(session, node_id),
         old = owning(session.tree, unit, session.components),
         {:ok, destination} <- destination(session, old, target) do
      moved_unit(session, unit, old, destination)
    end
  end

  defp unit_of(session, node_id) do
    with %Node{} = node <- Tree.get(session.tree, node_id),
         %Node{} = unit <- unit(session.tree, node, session.components) do
      {:ok, unit}
    else
      _not_a_field -> {:error, gettext("Only a field can move to another form.")}
    end
  end

  defp destination(_session, _old, @new), do: {:ok, :new}

  defp destination(session, old, target) do
    cond do
      old && old.id == target -> {:error, gettext("It is already in that form.")}
      List.keymember?(forms(session.tree), target, 0) -> {:ok, Tree.get(session.tree, target)}
      true -> {:error, gettext("That form is no longer on the page.")}
    end
  end

  defp moved_unit(session, unit, old, :new) do
    removed? = emptied?(session.tree, old, [unit], session.components)
    doomed = (removed? && old) || unit
    {parent, index} = new_spot(session.tree, unit, old, removed?)

    {:ok,
     [
       %{kind: :delete, node_id: doomed.id},
       %{kind: :insert, template: new_form(session, unit, old), parent_id: parent, index: index}
     ], moved_new_told(removed?)}
  end

  defp moved_unit(session, unit, old, form) do
    removed? = emptied?(session.tree, old, [unit], session.components)
    {parent, index} = landing(session.tree, form, session.components, dragged: unit)

    {:ok,
     [%{kind: :move, node_id: unit.id, parent_id: parent, index: index}] ++
       rebind_ops(session.tree, unit, let_of(old), form, session.components) ++
       removal(old, removed?), moved_to_told(form_name(form), removed?)}
  end

  defp moved_new_told(true),
    do: gettext("Moved it to a new form with a Send button. The empty form was removed.")

  defp moved_new_told(false), do: gettext("Moved it to a new form with a Send button.")

  defp moved_to_told(name, true),
    do: gettext("Moved it to %{form}. The empty form was removed.", form: phrase(name))

  defp moved_to_told(name, false), do: gettext("Moved it to %{form}.", form: phrase(name))

  defp removal(old, true), do: [%{kind: :delete, node_id: old.id}]
  defp removal(_old, false), do: []

  # Right after the form it leaves, or where the loose field stood.
  defp new_spot(tree, _unit, %Node{} = old, removed?),
    do: {old.parent_id, Tree.index_of(tree, old.id) + ((removed? && 0) || 1)}

  defp new_spot(tree, unit, nil, _removed?), do: {unit.parent_id, Tree.index_of(tree, unit.id)}

  # A new form around the field, with its Send button, the field bound to it.
  defp new_form(session, unit, old) do
    scratch = Tree.subtree(session.tree, unit.id)
    form = form_node(session)

    scratch
    |> Tree.wrap(unit.id, form)
    |> either(scratch)
    |> sent(form.id)
    |> rebound_unit(unit, let_of(old), session.components)
    |> Serializer.serialize()
  end

  defp rebound_unit(tree, unit, from_var, components) do
    tree
    |> unit_ops(unit, from_var, @let, [], components)
    |> Enum.reduce(tree, &applied(&2, &1))
  end

  defp rebind_ops(tree, unit, from_var, form, components),
    do: unit_ops(tree, unit, from_var, PageForms.let_var(form), taken(tree, form), components)

  # Every control of the unit bound to `to_var`, one fresh key per field it holds.
  defp unit_ops(tree, unit, from_var, to_var, taken, components) do
    nodes = [unit | descendants(tree, unit)]
    ctx = %{roles: Fields.roles(nodes, components), var: from_var}

    nodes
    |> Enum.map(&{identity(&1, ctx), &1})
    |> Enum.reject(fn {id, _node} -> is_nil(id) end)
    |> grouped()
    |> Enum.flat_map_reduce(taken, fn {id, members}, taken ->
      key = fresh_key(id, members, taken, components)

      {Enum.flat_map(members, &member_ops(&1, id, from_var, to_var, key, components)),
       [key | taken]}
    end)
    |> elem(0)
  end

  defp grouped(pairs) do
    order = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    by_id = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))

    Enum.map(order, &{&1, Map.fetch!(by_id, &1)})
  end

  defp fresh_key({:key, key}, _members, taken, _components),
    do: Naming.field_key(to_string(key), taken)

  defp fresh_key(_loose, [first | _rest], taken, components),
    do: Naming.field_key(label_of(first, components), taken)

  defp member_ops(node, {:key, key}, from_var, to_var, fresh, _components) do
    for {name, value} <- PageForms.rebindings(node, from_var, key, fresh, to_var),
        do: attr_op(node.id, {name, value})
  end

  defp member_ops(node, _loose, _from_var, to_var, fresh, components),
    do: binding_ops(node, components, to_var, fresh)

  defp emptied?(_tree, nil, _units, _components), do: false

  defp emptied?(tree, form, units, components) do
    gone = MapSet.new(units, & &1.id)

    remaining =
      tree
      |> descendants(form)
      |> Enum.reject(fn node ->
        MapSet.member?(gone, node.id) or
          Enum.any?(Tree.ancestors(tree, node.id), &MapSet.member?(gone, &1.id))
      end)

    ctx = %{roles: Fields.roles(remaining, components), var: PageForms.let_var(form)}

    not Enum.any?(remaining, &(identity(&1, ctx) != nil))
  end

  @doc """
  The ops that move every field of the form `from_id` into the form `into_id`, in order and in front
  of its first Send button, then remove `from_id`; one undo step, and the sentence the author is
  told.
  """
  @spec merge_ops(map(), String.t(), String.t()) ::
          {:ok, [map()], String.t()} | {:error, String.t()}
  def merge_ops(session, from_id, into_id) do
    working = forms(session.tree)

    with true <- from_id != into_id || {:error, gettext("Choose another form.")},
         true <-
           List.keymember?(working, from_id, 0) ||
             {:error, gettext("That form does not work yet.")},
         true <-
           List.keymember?(working, into_id, 0) ||
             {:error, gettext("That form is no longer on the page.")},
         from = Tree.get(session.tree, from_id),
         into = Tree.get(session.tree, into_id),
         [_first | _rest] = units <- units(session.tree, from, session.components) || [] do
      {:ok, merged(session, from, into, units),
       gettext("Moved its fields to %{form}. The empty form was removed.",
         form: phrase(form_name(into))
       )}
    else
      [] -> {:error, gettext("That form has no fields to move.")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merged(session, from, into, units) do
    {parent, index} = landing(session.tree, into, session.components, dragged: units)
    from_var = PageForms.let_var(from)
    to_var = PageForms.let_var(into)

    {moves, {rebinds, _taken}} =
      units
      |> Enum.with_index()
      |> Enum.map_reduce({[], taken(session.tree, into)}, fn {unit, at}, {rebinds, taken} ->
        ops = unit_ops(session.tree, unit, from_var, to_var, taken, session.components)

        {%{kind: :move, node_id: unit.id, parent_id: parent, index: index + at},
         {rebinds ++ ops, taken ++ written_keys(ops)}}
      end)

    moves ++ rebinds ++ [%{kind: :delete, node_id: from.id}]
  end

  # The keys a run of rebinding ops writes, so the next field does not take them.
  defp written_keys(ops) do
    for %{kind: :set_attr, value: value} <- ops,
        [_all, key] <- [Regex.run(~r/\[:([a-z0-9_]+)\]/, value)],
        uniq: true,
        do: key
  end

  @doc """
  How a drag of the existing node `params["node_id"]` lands, when it is a field on a Page.

  `params["index"]` is counted as `Tree.move/4` counts it, with the dragged node already out of its
  row.

  `{:plain, params}` is an ordinary move, its spot kept in front of its form's Send button. A field
  dragged into another form or out of every form answers `{:run, ops, sentence}`: its whole field
  (`unit/3`) moved and rebound into the other form, or a new form with a Send button around it, as
  one undo step. A form that binds no variable takes the field as it is.
  """
  @spec moving(map(), map()) :: {:plain, map()} | {:run, [map()], String.t()}
  def moving(session, %{"node_id" => id} = params) when is_binary(id) do
    with true <- page_forms?(session),
         %Node{} = node <- Tree.get(session.tree, id),
         %Node{} = unit <- unit(session.tree, node, session.components),
         false <- inside_itself?(session.tree, unit, parent_param(params)) do
      moved(session, node, unit, params)
    else
      _plain -> {:plain, params}
    end
  end

  def moving(_session, params), do: {:plain, params}

  defp inside_itself?(_tree, _node, nil), do: false

  defp inside_itself?(tree, node, parent),
    do: parent == node.id or Tree.descendant?(tree, node.id, parent)

  defp moved(session, node, unit, params) do
    old = owning(session.tree, unit, session.components)

    session |> hosting(params) |> carried(session, node, unit, old, params)
  end

  # Inside its own form the dragged node alone moves; into another form, or out of every form, its
  # whole field goes.
  defp carried({%Node{id: id}, _how} = hosting, session, node, _unit, %Node{id: id}, params) do
    {_form, spot} = hosted(hosting, session, params, node, session.tree)

    {:plain, reindexed(session.tree, node, params, spot)}
  end

  defp carried(nil, session, node, unit, old, params), do: fresh(session, node, unit, old, params)

  defp carried(hosting, session, _node, unit, old, params) do
    {form, spot} = hosted(hosting, session, params, unit, session.tree)

    into(session, unit, old, form, reindexed(session.tree, unit, params, spot))
  end

  # `Tree.move/4` counts its index with the node already taken out of its parent.
  defp reindexed(_tree, _node, params, spot) when map_size(spot) == 0, do: params

  defp reindexed(tree, node, params, %{"parent_id" => parent, "index" => index} = spot) do
    shift = ((node.parent_id == parent and (Tree.index_of(tree, node.id) || 0) < index) && 1) || 0

    Map.merge(params, %{spot | "index" => index - shift})
  end

  defp into(session, unit, old, form, params),
    do: form |> PageForms.let_var() |> into_var(session, unit, old, form, params)

  # A form with no `:let` binds nothing, so the field moves as it is.
  defp into_var(nil, _session, unit, _old, _form, params),
    do: {:plain, Map.put(params, "node_id", unit.id)}

  defp into_var(_var, session, unit, old, form, params) do
    removed? = emptied?(session.tree, old, [unit], session.components)

    {:run,
     [%{kind: :move, node_id: unit.id, parent_id: params["parent_id"], index: params["index"]}] ++
       rebind_ops(session.tree, unit, let_of(old), form, session.components) ++
       removal(old, removed?), joined_told(form_name(form), removed?)}
  end

  defp fresh(session, node, unit, old, params) do
    removed? = emptied?(session.tree, old, [unit], session.components)
    doomed = (removed? && old) || unit

    {:run,
     [
       %{kind: :delete, node_id: doomed.id},
       %{
         kind: :insert,
         template: new_form(session, unit, old),
         parent_id: parent_param(params),
         index: shifted(session.tree, doomed, node, parent_param(params), params["index"])
       }
     ], started_told(removed?)}
  end

  # The spot's index once `doomed` has left the same parent in front of it. The dragged node's own
  # leaving is already counted in `params`.
  defp shifted(tree, %Node{id: id}, %Node{id: id}, parent, index),
    do: to_index(index, length(Tree.child_ids(tree, parent || :root)))

  defp shifted(tree, doomed, _node, parent, index) do
    at = index |> to_index(length(Tree.child_ids(tree, parent || :root)))

    case doomed.parent_id == parent and (Tree.index_of(tree, doomed.id) || 0) < at do
      true -> at - 1
      false -> at
    end
  end
end
