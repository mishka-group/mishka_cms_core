defmodule MishkaCmsCore.Accounts.CaptchaCheck do
  @moduledoc """
  The captcha (`MishkaCmsCore.Captcha`) in the actions a visitor fills a form for:
  `sign_in_with_password`, `register_with_password`, `request_password_reset_token` and
  `request_magic_link`, each taking the token as its `captcha_token` argument. Checked in the
  action, so the sign-in pages and the `/api/auth` routes ask it alike.

  ## Where in the action

  A `before_action` — a `before_transaction` on a create, so the provider is not asked inside a
  database transaction — between the action's two rate limits:

      prepare rate_limit(per address)
      prepare &CaptchaCheck.prepare(&1, &2, :sign_in)
      prepare rate_limit(per account)

  The per-address limit comes first, so one address sending tokens that fail costs the provider no
  more requests than that limit lets through. The per-account limit comes after, so attempts that
  never passed the captcha cannot use up an account's tries and lock its owner out. The password is
  checked after both — a bot that fails the captcha never learns whether it was right — and a
  registration is checked only once its fields are valid, so a typo does not spend the token.

  ## Who is not asked

    * a scope that asks none — no provider, or one missing a key;
    * the JSON:API, whose requests `MishkaCmsCore.Runtime.Plugs.AuthRateLimitPlug` marks (`api?: true`
      in `ash_authentication_request`): its clients are apps, which have no captcha to show;
    * a call made with `authorize?: false` — the installer, the seeds, the console;
    * the second step of a password sign-in, once the first passed it: the sign-in page builds the
      code step's form with `captcha_passed?: true` in its context, which only server code can set.

  ## The answer

  A refusal is a `MishkaCmsCore.Accounts.CaptchaCheck.Refused` and fires
  `"auth:captcha:refused"` with `%{form, reason, detail, site_id}`. A provider that could not be
  asked lets the form through and fires `"auth:captcha:unavailable"` with `%{form, detail,
  site_id}`; both with `return: false`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  require Logger

  alias MishkaCmsCore.Accounts.CaptchaCheck.Refused
  alias MishkaCmsCore.Captcha
  alias MishkaInstaller.Event.Hook

  @type form :: :sign_in | :register | :reset_request | :magic_link

  @doc "A preparation: checks the captcha of a read or generic action's `form` before it runs."
  @spec prepare(Ash.Query.t() | Ash.ActionInput.t(), map(), form()) ::
          Ash.Query.t() | Ash.ActionInput.t()
  def prepare(%Ash.Query{} = query, _context, form),
    do: Ash.Query.before_action(query, &check(&1, form))

  def prepare(%Ash.ActionInput{} = input, _context, form),
    do: Ash.ActionInput.before_action(input, &check(&1, form))

  @doc """
  A change: checks the captcha of a create action's `form` before it runs — before its transaction,
  so a slow provider holds no database connection.
  """
  @spec change(Ash.Changeset.t(), map(), form()) :: Ash.Changeset.t()
  def change(changeset, _context, form),
    do: Ash.Changeset.before_transaction(changeset, &check(&1, form))

  defp check(subject, form) do
    if asked?(subject) do
      subject
      |> token()
      |> Captcha.check(subject.tenant, form, request(subject))
      |> answered(subject, form)
    else
      subject
    end
  end

  # `authorize?` AS THE ACTION RUNS, read off the subject in the hook: a generic action hands its
  # preparations `false` whenever the caller named none, so the preparation's context cannot tell a
  # visitor's form from the installer.
  defp asked?(subject) do
    get_in(subject.context, [:private, :authorize?]) != false and
      subject.context[:captcha_passed?] != true and
      get_in(subject.context, [:ash_authentication_request, :api?]) != true
  end

  defp token(%Ash.Query{} = query), do: Ash.Query.get_argument(query, :captcha_token)
  defp token(%Ash.ActionInput{} = input), do: Ash.ActionInput.get_argument(input, :captcha_token)

  defp token(%Ash.Changeset{} = changeset),
    do: Ash.Changeset.get_argument(changeset, :captcha_token)

  defp request(subject) do
    case subject.context[:ash_authentication_request] do
      %{remote_ip: address} when is_binary(address) -> %{remote_ip: address}
      _no_address -> %{remote_ip: nil}
    end
  end

  defp answered(:ok, subject, _form), do: subject

  defp answered({:error, {:unavailable, detail}}, subject, form) do
    Logger.warning(
      "Captcha could not be checked, so the form went through: form=#{form} site=#{subject.tenant || "master"} detail=#{detail}"
    )

    Hook.call(
      "auth:captcha:unavailable",
      %{form: form, detail: detail, site_id: subject.tenant},
      return: false
    )

    subject
  end

  defp answered({:error, refusal}, subject, form) do
    {reason, detail} =
      case refusal do
        :missing -> {:missing, "no token"}
        {:failed, detail} -> {:failed, detail}
      end

    Hook.call(
      "auth:captcha:refused",
      %{form: form, reason: reason, detail: detail, site_id: subject.tenant},
      return: false
    )

    add_error(subject, Refused.exception(reason: reason, form: form, site_id: subject.tenant))
  end

  defp add_error(%Ash.Query{} = query, error), do: Ash.Query.add_error(query, error)

  defp add_error(%Ash.Changeset{} = changeset, error),
    do: Ash.Changeset.add_error(changeset, error)

  # A GENERIC ACTION RUNS AN INPUT ITS HOOKS MADE INVALID — only an `{:error, _}` from the hook
  # stops it, which is how `ash_rate_limiter` refuses one too.
  defp add_error(%Ash.ActionInput{}, error), do: {:error, error}

  @doc """
  The captcha refusal anywhere inside `reason`, or `nil`: an error or error class, a form's
  `raw_errors`, or an `AshAuthentication.Errors.AuthenticationFailed`.

      CaptchaCheck.refusal(AshPhoenix.Form.raw_errors(form, for_path: :all))
      #=> %{reason: :missing}
  """
  @spec refusal(term()) :: %{reason: :missing | :failed} | nil
  def refusal(%Refused{reason: reason}), do: %{reason: reason}
  def refusal(%{caused_by: cause}), do: refusal(cause)
  def refusal(%{errors: errors}) when is_list(errors), do: refusal(errors)
  def refusal(errors) when is_list(errors), do: Enum.find_value(errors, &refusal/1)
  def refusal(%{} = errors) when not is_struct(errors), do: errors |> Map.values() |> refusal()
  def refusal(_other), do: nil

  @doc "What to tell whoever was refused, in their language."
  @spec describe(:missing | :failed) :: %{title: String.t(), text: String.t()}
  def describe(:missing),
    do: %{
      title: gettext("Complete the security check"),
      text: gettext("Then send the form again.")
    }

  def describe(_failed),
    do: %{
      title: gettext("The security check did not pass"),
      text: gettext("Try the check again, then send the form.")
    }
end
