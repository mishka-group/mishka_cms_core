# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.PageForms.FormChecks do
  @moduledoc """
  The Forms group of the audit rail: what is wrong with the page's forms, and the tree edit that
  puts each one right.

  Every finding carries the shape the rail already renders — `node_id`, `group`, `severity`, `rule`,
  `message`, `detail` — so a form check reads beside an accessibility one and its Fix button is the
  same button. What is different is that most of these have a mechanical answer: `repair/3` hands
  back the ops that fix the document, and the few with no edit behind them say why rather than
  appearing to work.

  ## What is asked of each node

  Not asked here at all: `MishkaCmsCore.Runtime.Authoring.Fields.form_node?/2` and
  `MishkaCmsCore.Runtime.Authoring.Fields.field_node?/2` are the editor's one answer to both, so
  what the insert funnel treats as a form, what `MishkaCmsCore.Runtime.Authoring.Containment`
  refuses to nest, and what the audit reports on cannot disagree. This module used to carry its own
  copy of each, and so did the other two.

  ## Two questions about a submit button, two answers

  `form-no-submit` asks, per node and at any depth inside the form, whether anything sends it
  (`Fields.submit_node?/3`): a bare `<button>`, a kit button left to its default, the CMS's own
  `<.button>`. A button whose type is computed (`Fields.type_unread?/3`) may send it, so the rule
  stays quiet rather than offer a second Send button. `submit-no-form` asks the reverse about a button outside every form, and there only a
  written `type="submit"` or `"image"` counts (`Fields.explicit_submit?/3`), so a hero or dialog
  button stays quiet.

  ## Why a wrap is an insert and a delete

  `MishkaCmsCore.Runtime.Authoring.Op`'s `:wrap` builds a bare tag with no attributes, and a form
  is nothing without its five. There is also no id to write them onto: the wrapper is minted inside
  the combinator. So the field's own source is re-parsed, wrapped and bound in one go by
  `FormPlacement.wrap/3`, inserted where the field stood, and the field deleted — two ops in one
  `MishkaCmsBuilder.EditorSession.apply_ops/4` run, which is one undo step.

  ## A Fix that cannot act says so

  Two of these have no edit behind them, and each says why in a sentence the author reads instead
  of appearing to work: there is no form on the page to move a button into (`submit-no-form`);
  unwrapping this form would strand the fields inside it (`form-in-form`). `repair/3` answers
  `{:say, sentence}` for those, which is not the same as `:none` — `:none` is a stale click, and the
  assistant is the right place for a document that has moved on. Everything else here has exactly
  one right answer and takes it.

  ## A note for developers

  `form-no-destination` is a `:note`, not counted against the page: a form nobody wrote code for
  still checks its fields and thanks the visitor. A form that names no submit event and posts to its
  own `action` has somewhere to go, so it raises nothing (`receiver/2`).

  Its Fix finishes the form first, one edit per click: its name (`as`), then its source (`for`),
  then its submit event. A form with all three answers `{:code, event, sentence}`: the form's submit
  event, for the editor to open in the Code window, and the sentence to show someone who cannot
  write code.

  See `MishkaCmsCore.Runtime.Authoring.PageForms` for what declares a form in the first place, and
  `MishkaCmsCore.Runtime.Authoring.PageForms.Naming` for the five names a seed derives.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Authoring.Fields
  alias MishkaCmsCore.Runtime.Authoring.PageForms
  alias MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.Authoring.PageForms.Naming
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node
  alias MishkaCmsCore.Runtime.Authoring.Tree.Serializer
  alias MishkaCmsCore.Runtime.PageForm

  @group :forms

  # A FINDING NOBODY CAN CLEAR IS WORSE THAN NO FINDING. Most of these describe the page-form model —
  # the `as`, the source assign, the handler, the five derived names — and
  # `MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.build_page_forms/1` is the only compiler that
  # emits it. On a layout, an error page and a component the drop deliberately leaves a field bare
  # (`FormPlacement.page_forms?/1`), and this group called that same field a blocker whose Fix routes
  # back through that gate and answers `:none`, which swings the rail to the assistant instead of
  # editing; writing the form by hand only traded it for `form-no-destination`, whose sentence
  # promises visitors are thanked and code can receive the form. False where no compiler emits it.
  #
  # The three named here are HTML's own facts, so they are asked everywhere: the browser really does
  # drop a form inside a form, a form with nothing to submit it cannot be sent, and a submit button
  # outside every form has nothing to send. None of them reads the page-form model and none of their
  # Fixes routes through `FormPlacement.wrap/3` — a search box in a layout header is ordinary markup,
  # and these are the three things that can be wrong with it. A rule not named here is page-only,
  # which is the safe way round for one added later.
  @everywhere ~w(form-in-form form-no-submit submit-no-form)

  @doc """
  Every Forms finding this document raises, in document order, with the duplicate-name blockers
  last.

  `record` is the page being edited, read for the event handlers it declares; `session` is the
  editing session, read for the palette and for the section — a section whose compiler emits no form
  keeps only the rules HTML itself is wrong about.
  """
  @spec findings(Tree.t(), map() | nil, map()) :: [map()]
  def findings(tree, record, session) do
    nodes = Tree.walk(tree)
    roles = roles(nodes, session.components)
    rules = Fields.submit_rules(roles, session.components)
    received = {declared_events(record), PageForm.destination?()}

    raised =
      Enum.flat_map(nodes, &checks(tree, &1, {roles, rules, session}, received)) ++
        duplicates(tree) ++ duplicate_tokens(nodes, roles) ++ duplicate_keys(tree, nodes, roles)

    asked(FormPlacement.page_forms?(session), raised)
  end

  defp asked(true, raised), do: raised
  defp asked(false, raised), do: Enum.filter(raised, &(&1.rule in @everywhere))

  @doc """
  Whether these nodes hold a form at all.

  The rail's passing rows are conditional on it: "every form reaches a handler" is not a tick a page
  with no form has earned, it is a check that never ran — and on a section that compiles no form it
  is not a check at all.
  """
  @spec forms?([Node.t()], map()) :: boolean()
  def forms?(nodes, session), do: FormPlacement.page_forms?(session) and any_form?(nodes, session)

  # The memo is built once, not inside the capture: this runs on every render the rail is the open
  # tab, and a document of a thousand nodes rebuilt it a thousand times.
  defp any_form?(nodes, session) do
    roles = roles(nodes, session.components)

    Enum.any?(nodes, &form?(&1, roles))
  end

  @doc """
  The ops that fix `rule` on `node_id`, the sentence to show when there is nothing this can edit, or
  `:none`.

  `{:ops, ops}` is a run applied as one history entry; `{:op, op}` is a single edit; `{:say,
  sentence}` is a refusal the author reads, for the fixes whose answer is not in this document at
  all. A rule this module does not answer for, and a node that is no longer in the tree, both give
  `:none` — the caller falls back to the assistant, which is the right answer for a stale click.
  """
  @spec repair(map(), String.t(), String.t() | nil) ::
          {:op, map()}
          | {:ops, [map()]}
          | {:say, String.t()}
          | {:code, String.t(), String.t()}
          | :none
  def repair(session, rule, node_id), do: mend(rule, session, Tree.get(session.tree, node_id))

  @doc """
  The ops one of a finding's `fixes` makes, when it offers more than one: `"typing"` on
  `form-no-submit` makes the form work as they type (`FormPlacement.how_ops/3`). Any other fix is
  `repair/3`'s.
  """
  @spec repair(map(), String.t(), String.t() | nil, String.t() | nil) ::
          {:op, map()}
          | {:ops, [map()]}
          | {:say, String.t()}
          | {:code, String.t(), String.t()}
          | :none
  def repair(session, "form-no-submit", node_id, "typing") when is_binary(node_id) do
    case FormPlacement.how_ops(session, node_id, :typing) do
      {:ok, ops, _told} -> {:ops, ops}
      {:error, reason} -> {:say, reason}
    end
  end

  def repair(session, rule, node_id, _fix), do: repair(session, rule, node_id)

  @doc """
  Whether `rule` names one of this module's findings.

  Fix on such a finding is answered by `repair/3`; Fix on any other is handed to the assistant.
  """
  @spec rule?(term()) :: boolean()
  def rule?("form-" <> _rest), do: true
  def rule?("field-" <> _rest), do: true
  def rule?("submit-no-form"), do: true
  def rule?(_other), do: false

  defp mend(_rule, _session, nil), do: :none

  defp mend("field-no-form", session, node), do: rewrap(session, node)

  defp mend("field-no-key", session, node), do: key_ops(session, node)

  defp mend("form-no-as", session, node),
    do: {:op, expr_attr(node, "as", ":" <> seed(session, node))}

  defp mend("form-no-source", session, node),
    do: {:op, expr_attr(node, "for", "assigns[:#{seed(session, node)}_form]")}

  defp mend("form-duplicate-seed", session, node), do: renumber(session, node)

  defp mend("form-duplicate-token", session, node), do: retoken(session, node)

  defp mend("form-duplicate-source", _session, node), do: rederive(node)

  defp mend("field-duplicate-key", session, node), do: rekey_ops(session, node)

  defp mend("form-in-form", session, node),
    do: session.tree |> ancestor_form(node, roles(session)) |> outer_binding(session, node)

  defp mend("form-no-destination", session, node),
    do:
      {own_action(node), PageForms.param_name(node), PageForms.source_assign(node),
       submit_event(node)}
      |> destined(session, node)

  defp mend("form-no-change", session, node),
    do:
      {:op,
       string_attr(
         node,
         "phx-change",
         Naming.event(seed(session, node), Naming.form_token(node), :validate)
       )}

  defp mend("form-no-submit", session, node), do: {:op, button_op(session, node)}

  defp mend("submit-no-form", session, node), do: move_op(session, node)

  defp mend("field-name-shadow", _session, node),
    do: {:op, %{"kind" => "delete_attr", "node_id" => node.id, "name" => "name"}}

  defp mend(_unanswered, _session, _node), do: :none

  # A form posting to its own address raises no note, so a Fix for it is a stale click. Any other
  # form is given its name, then its source, then its submit event, one edit per click; a form with
  # all of them is answered in code.
  defp destined({action, _as, _source, nil}, _session, _node) when is_binary(action), do: :none

  defp destined({_action, nil, _source, _event}, session, node),
    do: mend("form-no-as", session, node)

  defp destined({_action, _as, nil, _event}, session, node),
    do: mend("form-no-source", session, node)

  defp destined({_action, _as, _source, nil}, session, node),
    do:
      {:op,
       string_attr(
         node,
         "phx-submit",
         Naming.event(seed(session, node), Naming.form_token(node), :submit)
       )}

  defp destined({_action, _as, _source, event}, _session, _node),
    do: {:code, event, no_destination()}

  defp no_destination do
    gettext(
      "Visitors are thanked, but what they type is not kept or sent anywhere yet. Ask whoever writes code for this site to add that."
    )
  end

  defp own_action(node), do: node |> Node.attr_text("action") |> presence()

  defp submit_event(node), do: node |> Node.attr_text("phx-submit") |> presence()

  defp rewrap(session, node) do
    session.tree
    |> Serializer.serialize_node(node.id)
    |> FormPlacement.wrap(session, node.parent_id)
    |> replace(session, node)
  end

  defp replace({_template, false}, _session, _node), do: :none

  defp replace({template, true}, session, node) do
    {:ops,
     [
       %{
         "kind" => "insert",
         "template" => template,
         "parent_id" => node.parent_id || "root",
         "index" => Tree.index_of(session.tree, node.id) || 0
       },
       %{"kind" => "delete", "node_id" => node.id}
     ]}
  end

  defp key_ops(session, node) do
    with %Node{} = form <- ancestor_form(session.tree, node, roles(session)),
         var when is_atom(var) and not is_nil(var) <- PageForms.let_var(form) do
      {:ops, bindings(session, node, form, var)}
    else
      _unbindable -> :none
    end
  end

  # WHICH attributes a binding writes, and which it supersedes, is
  # `MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacement.binding/4`'s answer. This used to be a
  # second copy of it, and the copies drifted: the insert funnel learned to drop the blank `name=""`
  # a palette card is seeded with, and the audit's Fix went on leaving it — so pressing Fix produced a
  # field that renders and submits nothing, which is the defect the drop exists to prevent.
  defp bindings(session, node, form, var) do
    node
    |> FormPlacement.binding(
      session.components,
      var,
      Naming.field_key(
        Fields.field_label(node, session.components),
        taken(session.tree, form)
      )
    )
    |> Enum.map(&binding_op(node, &1))
  end

  defp binding_op(node, {:set, name, value}), do: attr_op(node, {name, value})

  defp binding_op(node, {:drop, name}),
    do: %{"kind" => "delete_attr", "node_id" => node.id, "name" => name}

  defp rekey_ops(session, node) do
    with %Node{} = form <- ancestor_form(session.tree, node, roles(session)),
         var when is_atom(var) and not is_nil(var) <- PageForms.let_var(form),
         key when is_atom(key) and not is_nil(key) <- PageForms.bound_key(node, var) do
      {:ops, rekeyed(node, var, key, Naming.field_key(to_string(key), taken(session.tree, form)))}
    else
      _unbindable -> :none
    end
  end

  defp rekeyed(node, var, key, minted) do
    node
    |> PageForms.rebindings(var, key, minted)
    |> Enum.map(fn {name, {:expr, source}} -> expr_attr(node, name, source) end)
  end

  defp renumber(session, node),
    do:
      rewrite(
        node,
        Naming.unique(session.tree, PageForms.param_name(node)),
        Naming.kept_token(session.tree, node)
      )

  # THE PARAM NAME IS ALREADY THIS FORM'S OWN — only the page assign collided, so re-deriving all
  # five from it is the whole repair and renumbering would rename a form nobody else is competing
  # with. A form that also shares its param name carries the other blocker, and that one renumbers.
  defp rederive(node), do: rewrite(node, PageForms.param_name(node), Naming.form_token(node))

  defp rewrite(node, seed, token) do
    node
    |> Naming.names_for(seed, token)
    |> Enum.map(&attr_op(node, &1))
    |> then(&{:ops, &1})
  end

  # Gives the later of two forms sharing a token a fresh one, in the event names it owns.
  defp retoken(session, node) do
    node
    |> Naming.retokened(Naming.mint_token(session.tree))
    |> Enum.map(&attr_op(node, &1))
    |> retokened()
  end

  defp retokened([]), do: :none
  defp retokened(ops), do: {:ops, ops}

  defp attr_op(node, {name, {:expr, source}}), do: expr_attr(node, name, source)
  defp attr_op(node, {name, {:string, value}}), do: string_attr(node, name, value)

  defp button_op(session, node) do
    %{
      "kind" => "insert",
      "template" => FormPlacement.send_button(),
      "parent_id" => node.id,
      "index" => length(Tree.child_ids(session.tree, node.id))
    }
  end

  defp move_op(session, node), do: session |> all_forms() |> destination_form(session, node)

  defp all_forms(session) do
    nodes = Tree.walk(session.tree)
    roles = roles(nodes, session.components)

    Enum.filter(nodes, &form?(&1, roles))
  end

  defp destination_form([], _session, _node),
    do: {:say, gettext("There is no form on this page to put it in yet.")}

  defp destination_form([form], session, node), do: {:op, move_into(session, form, node)}

  # SEVERAL FORMS IS STILL A DECISION THE EDITOR CAN MAKE. It used to hand the author to the
  # assistant, which from their seat is a Fix button that only changes panels — on the one page where
  # both candidates are known and the button is sitting right after one of them. That one is the
  # answer, and an author who meant the other has a drag and an undo.
  defp destination_form(forms, session, node),
    do: {:op, move_into(session, nearest(forms, session, node), node)}

  defp move_into(session, form, node),
    do: %{
      "kind" => "move",
      "node_id" => node.id,
      "parent_id" => form.id,
      "index" => length(Tree.child_ids(session.tree, form.id))
    }

  # The last form that opens above the button, and the first one below it when none does. Measuring
  # the gap instead would make the answer depend on how many children each form has, so a long form
  # the button sits directly under would lose to a short one further down the page.
  defp nearest(forms, session, node) do
    order =
      session.tree |> Tree.walk() |> Enum.with_index() |> Map.new(fn {n, i} -> {n.id, i} end)

    forms
    |> Enum.split_with(&(Map.fetch!(order, &1.id) < Map.fetch!(order, node.id)))
    |> above_or_below()
  end

  defp above_or_below({[], [below | _rest]}), do: below
  defp above_or_below({above, _below}), do: List.last(above)

  defp outer_binding(outer, session, node),
    do: node |> PageForms.let_var() |> unwrappable(PageForms.let_var(outer), session, node)

  # UNWRAPPING DELETES THE `:let` THE FIELDS INSIDE ARE BOUND TO. The form around it binding the same
  # variable is the one case where they still resolve; binding a different one, or none, leaves every
  # field reading a variable nothing binds — and that is no longer a warning, it is a page
  # `MishkaCmsCore.Runtime.Authoring.CodeCheck` refuses to store at all. A Fix must not turn one
  # into the other.
  defp unwrappable(var, var, _session, node), do: {:op, unwrap_op(node)}

  defp unwrappable(var, _outer_var, session, node),
    do: session.tree |> descendants(node) |> Enum.any?(&bound?(&1, var)) |> stranding(node)

  defp stranding(true, _node),
    do:
      {:say,
       gettext(
         "The fields inside it read this form by name, so taking it away stops the page working."
       )}

  defp stranding(false, node), do: {:op, unwrap_op(node)}

  defp unwrap_op(node), do: %{"kind" => "unwrap", "node_id" => node.id}

  defp bound?(nil, _var), do: false
  defp bound?(node, var), do: PageForms.bound_key(node, var) != nil

  defp expr_attr(node, name, source),
    do: %{
      "kind" => "set_attr",
      "node_id" => node.id,
      "name" => name,
      "value" => source,
      "value_kind" => "expr"
    }

  defp string_attr(node, name, value),
    do: %{"kind" => "set_attr", "node_id" => node.id, "name" => name, "value" => value}

  defp seed(session, node), do: node |> PageForms.param_name() |> minted(session, node)

  defp minted(nil, session, node),
    do: Naming.unique(session.tree, node |> Node.attr_text("id") |> without_suffix())

  defp minted(parsed, _session, _node), do: Naming.seed(parsed)

  defp without_suffix(nil), do: nil
  defp without_suffix(id), do: String.replace_suffix(id, "-form", "")

  defp checks(tree, node, {roles, rules, _session} = memo, received) do
    form_checks(form?(node, roles), tree, node, memo, received) ++
      field_checks(field?(node, roles), tree, node, roles) ++
      submit_checks(Fields.explicit_submit?(node, roles, rules), tree, node, roles)
  end

  defp form_checks(false, _tree, _node, _memo, _received), do: []

  defp form_checks(true, tree, node, {roles, rules, session}, received) do
    Enum.reject(
      [
        as_finding(node),
        source_finding(node),
        destination_finding(node, received),
        nesting_finding(tree, node, roles),
        change_finding(node),
        button_finding(tree, node, roles, rules, session)
      ],
      &is_nil/1
    )
  end

  defp as_finding(node), do: node |> PageForms.param_name() |> named(node)

  defp named(nil, node),
    do:
      finding(
        node,
        :blocker,
        "form-no-as",
        gettext("This form has no name of its own"),
        gettext("Two forms on this page would mix up each other's answers.")
      )

  defp named(_as, _node), do: nil

  defp source_finding(node), do: node |> PageForms.source_assign() |> sourced(node)

  defp sourced(nil, node),
    do:
      finding(
        node,
        :blocker,
        "form-no-source",
        gettext("This form has nowhere to keep what was typed"),
        gettext("It comes back empty every time, and never says what was wrong.")
      )

  defp sourced(_assign, _node), do: nil

  defp destination_finding(node, received), do: node |> received_by(received) |> reached(node)

  defp reached(:none, node),
    do:
      finding(
        node,
        :note,
        "form-no-destination",
        gettext("Nothing receives this form"),
        gettext(
          "Visitors see the Success message, but what they type is not kept or sent anywhere yet."
        )
      )

  defp reached(_receiver, _node), do: nil

  defp nesting_finding(tree, node, roles), do: tree |> ancestor_form(node, roles) |> nested(node)

  defp nested(nil, _node), do: nil

  defp nested(_outer, node),
    do:
      finding(
        node,
        :warning,
        "form-in-form",
        gettext("This form is inside another form"),
        gettext("Browsers drop the inner one and everything after it stops submitting.")
      )

  defp change_finding(node),
    do: node |> Node.attr_text("phx-change") |> presence() |> checked(node)

  defp checked(nil, node),
    do:
      finding(
        node,
        :warning,
        "form-no-change",
        gettext("This form checks only when sent"),
        gettext(
          "The visitor finds out what they got wrong after they press Send, not while they type."
        )
      )

  defp checked(_event, _node), do: nil

  # A form that works as they type has no Send button by choice.
  defp button_finding(tree, node, roles, rules, session) do
    (PageForms.as_typed?(node) or
       tree
       |> descendants(node)
       |> Enum.any?(
         &(Fields.submit_node?(&1, roles, rules) or Fields.type_unread?(&1, roles, rules))
       ))
    |> submittable(node, session)
  end

  defp submittable(true, _node, _session), do: nil

  defp submittable(false, node, session),
    do:
      node
      |> finding(
        :warning,
        "form-no-submit",
        gettext("This form has no submit button"),
        gettext("Most visitors will have no way to send it.")
      )
      |> Map.put(:fixes, send_fixes(FormPlacement.as_typed_offered?(session, node)))

  # A form the Form panel lets work as they type is offered that too.
  defp send_fixes(true),
    do: [
      %{fix: "send", label: gettext("Add a Send button")},
      %{fix: "typing", label: gettext("Make it work as they type")}
    ]

  defp send_fixes(false), do: [%{fix: "send", label: gettext("Add a Send button")}]

  defp field_checks(false, _tree, _node, _roles), do: []

  defp field_checks(true, tree, node, roles),
    do: tree |> ancestor_form(node, roles) |> field_findings(node)

  # TWO COSTS UNDER ONE RULE, because they really are that far apart. A control that names itself
  # renders and submits nothing. A field the editor bound is still reading the `:let` variable of the
  # form it was dragged out of, nothing binds it any more, and
  # `MishkaCmsCore.Runtime.Authoring.CodeCheck` — which runs on the page's own action — refuses to
  # store the page at all. Saying "what the visitor types never leaves the page" about the second one
  # describes a page that still works, minus one field.
  defp field_findings(nil, node), do: [stranded(node, PageForms.bound_var(node))]

  defp field_findings(form, node), do: bound(node, PageForms.let_var(form))

  defp stranded(node, nil),
    do:
      finding(
        node,
        :blocker,
        "field-no-form",
        gettext("This field is not inside a form"),
        gettext("Nothing submits it, so what the visitor types never leaves the page.")
      )

  defp stranded(node, _var),
    do:
      finding(
        node,
        :blocker,
        "field-no-form",
        gettext("This field is not inside a form"),
        gettext("This page cannot be saved until it is back inside a form.")
      )

  defp bound(node, var),
    do: Enum.reject([key_finding(node, var), shadow_finding(node, var)], &is_nil/1)

  defp key_finding(node, var), do: node |> keyed?(var) |> keyed(node)

  defp keyed(true, _node), do: nil

  defp keyed(false, node),
    do:
      finding(
        node,
        :blocker,
        "field-no-key",
        gettext("This field has no name"),
        gettext("Two unnamed fields overwrite each other on submit.")
      )

  # ASKED WITHOUT MINTING ANYTHING. This runs for every field on the page on every render while the
  # rail is the open tab, and `PageForms.field_key/2` would intern the `name=` the author is halfway
  # through typing — one permanent atom per keystroke. The two answers are the same: a control whose
  # own `name` is what makes it keyed already answers the second half.
  defp keyed?(node, var),
    do: PageForms.bound_key(node, var) != nil or Node.literal(node, "name") != nil

  defp shadow_finding(node, var),
    do: node |> PageForms.bound_key(var) |> shadowed(node, Node.literal(node, "name"))

  defp shadowed(nil, _node, _name), do: nil
  defp shadowed(_key, _node, nil), do: nil

  defp shadowed(_key, node, name),
    do:
      finding(
        node,
        :warning,
        "field-name-shadow",
        gettext("This field's name overrides its binding"),
        gettext(
          "What the visitor types arrives under %{name}, which nothing on this page is checking.",
          name: name
        )
      )

  defp submit_checks(false, _tree, _node, _roles), do: []

  defp submit_checks(true, tree, node, roles),
    do: tree |> ancestor_form(node, roles) |> stray(node)

  defp stray(nil, node),
    do: [
      finding(
        node,
        :warning,
        "submit-no-form",
        gettext("This submit button is not inside a form"),
        gettext("It has nothing to send.")
      )
    ]

  defp stray(_form, _node), do: []

  # Renumbering runs at the op layer, so the editor's own routes cannot produce two forms with one
  # name. The code drawer, an import and a template written by hand still can, and each of them
  # gives both forms the same id, the same param name and the same page assign.
  #
  # TWO AXES, BECAUSE THE FIVE NAMES CAN DISAGREE. Grouping by the param name alone missed the pair
  # that shares a page assign and nothing else, which is one code-drawer edit away — duplicate a form
  # and change only the copy's `as`. `MishkaCmsCore.Runtime.PageForm.validate/4` resolves a spec by
  # its assign and takes the first match, so the copy posts under a param name the first spec does
  # not scope, reads back `%{}`, and re-assigns the shared assign from nothing: every keystroke in
  # the second form empties the first, which renders from it. The audit said the page was clean.
  defp duplicates(tree) do
    seeded = seed_duplicates(tree)

    seeded ++ source_duplicates(tree, MapSet.new(seeded, & &1.node_id))
  end

  defp seed_duplicates(tree) do
    tree
    |> Naming.seeds()
    |> Enum.map(fn {node_id, parsed} -> {Naming.seed(parsed), node_id} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(&repeated(&1, tree))
  end

  defp repeated({seed, [_first | rest]}, tree),
    do: Enum.map(rest, &duplicate_finding(tree, &1, seed))

  # Every form carrying a token an earlier form already carries, in document order.
  defp duplicate_tokens(nodes, roles) do
    nodes
    |> Enum.filter(&form?(&1, roles))
    |> Enum.flat_map_reduce(MapSet.new(), &tagged/2)
    |> elem(0)
  end

  defp tagged(node, seen), do: node |> Naming.form_token() |> seen_token(node, seen)

  defp seen_token(nil, _node, seen), do: {[], seen}

  defp seen_token(token, node, seen),
    do: {token_findings(MapSet.member?(seen, token), node), MapSet.put(seen, token)}

  defp token_findings(false, _node), do: []

  defp token_findings(true, node),
    do: [
      finding(
        node,
        :blocker,
        "form-duplicate-token",
        gettext("Two forms answer to the same handlers"),
        gettext("Code written for one of them can run when the other one is sent.")
      )
    ]

  defp source_duplicates(tree, reported) do
    tree
    |> assigns()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(&sharing(&1, tree, reported))
  end

  defp assigns(tree) do
    for node <- Tree.walk(tree),
        assign = PageForms.source_assign(node),
        !is_nil(assign),
        do: {assign, node.id}
  end

  # A form already carrying the duplicate-name blocker is not told twice: renumbering it rewrites all
  # five names, which is the same repair either finding would ask for.
  defp sharing({assign, [_first | rest]}, tree, reported),
    do:
      rest
      |> Enum.reject(&MapSet.member?(reported, &1))
      |> Enum.map(&source_finding(tree, &1, assign))

  defp source_finding(tree, node_id, assign),
    do:
      tree
      |> Tree.get(node_id)
      |> finding(
        :blocker,
        "form-duplicate-source",
        gettext("Two forms keep what is typed in the same place"),
        gettext("Both read %{assign}, so typing in this one empties the other.", assign: assign)
      )

  # Re-keying runs at the op layer too, so the editor's own routes cannot produce two fields under
  # one key. The code drawer, an import and a template written by hand still can, and there the
  # visitor's later value silently replaces the earlier one on submit.
  #
  # A CONTROL CARRYING ITS OWN WRITTEN VALUE IS NOT A SECOND FIELD: a checkbox's `true` beside the
  # hidden `false`, or every option in a radio group, is one value under one key by design, and so
  # is a `<label>`, which binds the key without being a field at all.
  #
  # Asked ONE FORM AT A TIME, because a key is only ever shared within one: each form scopes its own
  # params, so `contact[email]` and `newsletter[email]` are two fields that happen to be spelled the
  # same and collide nowhere.
  defp duplicate_keys(tree, nodes, roles) do
    nodes
    |> Enum.filter(&form?(&1, roles))
    |> Enum.flat_map(&within(tree, &1, roles))
  end

  defp within(tree, form, roles) do
    tree
    |> carriers(form, PageForms.let_var(form), roles)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(&shared/1)
  end

  defp carriers(_tree, _form, nil, _roles), do: []

  defp carriers(tree, form, var, roles) do
    for id <- Tree.descendant_ids(tree, form.id),
        node = Tree.get(tree, id),
        !is_nil(node),
        field?(node, roles),
        !Fields.written_value?(node),
        key = PageForms.bound_key(node, var),
        !is_nil(key),
        do: {key, node}
  end

  defp shared({_key, [_only]}), do: []

  defp shared({key, [_first | rest]}),
    do:
      Enum.map(
        rest,
        &finding(
          &1,
          :blocker,
          "field-duplicate-key",
          gettext("Two fields share the name \"%{key}\"", key: key),
          gettext(
            "They send one value, so whatever the visitor types in the second one replaces the first."
          )
        )
      )

  defp duplicate_finding(tree, node_id, seed),
    do:
      tree
      |> Tree.get(node_id)
      |> finding(
        :blocker,
        "form-duplicate-seed",
        gettext("Two forms share the name \"%{seed}\"", seed: seed),
        gettext("Typing in one of them shows up in the other.")
      )

  defp finding(node, severity, rule, message, detail) do
    %{
      node_id: node.id,
      group: @group,
      severity: severity,
      rule: rule,
      message: message,
      detail: detail
    }
  end

  defp form?(node, roles), do: Fields.form_node?(node, roles)

  defp field?(node, roles), do: Fields.field_node?(node, roles)

  defp ancestor_form(tree, node, roles),
    do: tree |> Tree.ancestors(node.id) |> Enum.find(&form?(&1, roles))

  defp descendants(tree, node),
    do: tree |> Tree.descendant_ids(node.id) |> Enum.map(&Tree.get(tree, &1))

  defp roles(nodes, components), do: Fields.roles(nodes, components)

  defp roles(session), do: roles(Tree.walk(session.tree), session.components)

  defp taken(tree, form), do: PageForms.names(tree, form)

  @doc """
  What receives this form's submissions, the check `form-no-destination` makes:

    * `:code` when a handler `record` stores answers the form's submit event
      (`PageForms.answered?/2`) with code that is not the untouched default
      (`LiveViewCompiler.untouched_handler?/3`);
    * `:plugin` when no such handler does and a plugin listens on `page:form:submitted`;
    * `:action` when the form posts to its own `action`: with no submit event, or once its answers
      are checked (`PageForms.sends_elsewhere?/1`);
    * `:none` otherwise.
  """
  @spec receiver(Node.t(), map() | nil) :: :code | :plugin | :action | :none
  def receiver(node, record),
    do: received_by(node, {declared_events(record), PageForm.destination?()})

  defp declared_events(%{events: events}) when is_list(events), do: events
  defp declared_events(_record), do: []

  # A form sending to another address once its answers are checked goes there.
  defp received_by(node, received) do
    case PageForms.sends_elsewhere?(node) do
      true -> :action
      false -> node |> submit_event() |> sent(node, received)
    end
  end

  defp sent(nil, node, _received), do: node |> own_action() |> posted()

  defp sent(event, _node, {entries, plugin?}),
    do:
      entries
      |> Enum.reject(&untouched?(&1, event))
      |> PageForms.answered?(event)
      |> by_code(plugin?)

  defp posted(nil), do: :none
  defp posted(_action), do: :action

  defp by_code(true, _plugin?), do: :code
  defp by_code(false, true), do: :plugin
  defp by_code(false, false), do: :none

  defp untouched?(entry, name),
    do: LiveViewCompiler.untouched_handler?(:submit, entry_code(entry), name)

  defp entry_code(%{code: code}), do: code
  defp entry_code(%{"code" => code}), do: code
  defp entry_code(_entry), do: nil

  defp presence(nil), do: nil
  defp presence(value), do: value |> String.trim() |> filled()

  defp filled(""), do: nil
  defp filled(value), do: value
end
