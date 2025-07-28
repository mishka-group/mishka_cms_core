defmodule MishkaCmsCore.Runtime.Resources.Validations.MasterSiteStays do
  @moduledoc """
  Keeps a master site that masters can sign in on.

  Masters sign in on the master site's web pages and nowhere else, so each of these would lock every
  master out with one click, and is refused:

  - switching off, archiving, deleting or unsetting the master site;
  - making the master site API-only through an edit;
  - moving the flag to a site that is switched off or API-only;
  - making a second master by creating or editing another site with the flag: `:set_as_master` is
    what moves it.

  Making another site master moves the flag, after which the old one can be changed.

      validate MasterSiteStays                         # :deactivate, :destroy, :permanent_destroy, :unset_as_master
      validate {MasterSiteStays, on: :update}          # :update
      validate {MasterSiteStays, on: :create}          # :create
      validate {MasterSiteStays, on: :set_as_master}   # :set_as_master
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  @stays dgettext_noop("errors", "This is the master site. Make another site master first.")
  @reachable dgettext_noop(
               "errors",
               "Masters sign in on the master site's web pages, so it must be switched on and take web visits."
             )
  @one dgettext_noop(
         "errors",
         "Another site is the master site. Use Set Master to move it to this one."
       )

  @impl true
  def validate(changeset, opts, _context) do
    case refusal(changeset, opts[:on]) do
      nil -> :ok
      {field, message} -> {:error, field: field, message: message}
    end
  end

  defp refusal(%{data: %{master: true}}, nil), do: {:master, @stays}
  defp refusal(_changeset, nil), do: nil

  defp refusal(%{data: %{master: true}} = changeset, :update) do
    cond do
      turned_off?(changeset, :active) or turned_off?(changeset, :master) -> {:master, @stays}
      Ash.Changeset.get_attribute(changeset, :mode) == :api_only -> {:mode, @reachable}
      true -> nil
    end
  end

  defp refusal(changeset, on) when on in [:update, :create] do
    if Ash.Changeset.get_attribute(changeset, :master) == true,
      do: another_master(changeset) || unreachable(changeset),
      else: nil
  end

  defp refusal(changeset, :set_as_master), do: unreachable(changeset)

  defp turned_off?(changeset, attribute) do
    Ash.Changeset.changing_attribute?(changeset, attribute) and
      Ash.Changeset.get_attribute(changeset, attribute) == false
  end

  defp unreachable(changeset) do
    if Ash.Changeset.get_attribute(changeset, :active) == false or
         Ash.Changeset.get_attribute(changeset, :mode) == :api_only,
       do: {:master, @reachable},
       else: nil
  end

  defp another_master(changeset) do
    id = Ash.Changeset.get_attribute(changeset, :id)
    masters = Ash.Query.filter(changeset.resource, master == true)
    others = if is_nil(id), do: masters, else: Ash.Query.filter(masters, id != ^id)

    if Ash.exists?(others, authorize?: false), do: {:master, @one}
  end
end
