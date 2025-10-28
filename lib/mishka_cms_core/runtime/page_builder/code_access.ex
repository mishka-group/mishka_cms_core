defmodule MishkaCmsCore.Runtime.PageBuilder.CodeAccess do
  @moduledoc """
  Whether this deployment allows code written by hand, and what a refusal says.

  Code is what a person TYPES that the site then runs:

    * Elixir — `events`, `infos` and `helpers` on `Page`, and `helpers` on `Layout`, `Component`
      and `ErrorPage` (`fields/0`), and on their drafts;
    * HEEx typed by hand — `template`, `root_layout_template` and an error page's per-status
      templates, written through a form, the admin JSON:API or the builder's Template source tab;
    * browser code — a JS hook's content and a stylesheet's content.

  ## Who may write it

  Whoever may write the record: its own runtime area (`admin:<surface>:runtime:<type>`) or
  `admin:<surface>:code`, which writes every type that holds code. The resource's policies ask it.

  ## The deployment

  `config :mishka_cms_core, :page_code, :off` stops code the SERVER runs — the Elixir and the
  hand-written HEEx — for everybody, master included
  (`MishkaCmsCore.Runtime.Resources.Validations.CodeChange`). Browser code is not run by the server
  and is not affected.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  @doc "The attributes author-written Elixir is stored in. A resource declares whichever it has."
  @spec fields() :: [atom()]
  def fields, do: [:events, :infos, :helpers]

  @doc """
  Whether this deployment allows code the server runs — Elixir and hand-written HEEx.

  `:on` unless configured otherwise. Turning it OFF stops new code being stored; it does not stop
  code already in the database from compiling.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:mishka_cms_core, :page_code, :on) != :off

  @doc """
  Why a write of code was refused, in words for the person who hit it: the deployment turned it
  off, or the write names nobody who may write it.
  """
  @spec refusal() :: String.t()
  def refusal do
    case enabled?() do
      false -> gettext("Author-written Elixir is turned off on this deployment (:page_code).")
      true -> gettext("You do not have permission to change page code.")
    end
  end
end
