# How AshJsonApi and AshPhoenix forms show a refused sign-in action: an `ash_rate_limiter` refusal
# (`MishkaCmsCore.Accounts.AuthRateLimit`), a way in a site has closed
# (`MishkaCmsCore.Accounts.AuthGate`), a second factor still owed
# (`MishkaCmsCore.Accounts.SecondFactor`) and a captcha not passed
# (`MishkaCmsCore.Accounts.CaptchaCheck`, which the JSON:API never asks). Protocol
# implementations, so they sit together here rather than with any one library's callers.

defimpl AshJsonApi.ToJsonApiError, for: AshRateLimiter.LimitExceeded do
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.AuthRateLimit

  def to_json_api_error(error) do
    case AuthRateLimit.limited(error) do
      nil ->
        %AshJsonApi.Error{
          status_code: 429,
          code: "rate_limited",
          title: gettext("Too many requests"),
          detail: gettext("Too many requests. Try again later."),
          log_level: :debug
        }

      limited ->
        %{title: title, text: text} = AuthRateLimit.describe(limited)

        %AshJsonApi.Error{
          status_code: 429,
          code: "rate_limited",
          title: title,
          detail: gettext("%{title}. %{text}", title: title, text: text),
          meta: %{
            retry_after: limited.retry_after,
            action: limited.action,
            limited_by: limited.key
          },
          log_level: :debug
        }
    end
  end
end

defimpl AshPhoenix.FormData.Error, for: AshRateLimiter.LimitExceeded do
  def to_form_error(_error), do: []
end

defimpl AshJsonApi.ToJsonApiError, for: MishkaCmsCore.Accounts.AuthGate.Closed do
  def to_json_api_error(%{action: action}) do
    %{title: title, text: text} = MishkaCmsCore.Accounts.AuthGate.describe(action)

    %AshJsonApi.Error{
      status_code: 403,
      code: "auth_closed",
      title: title,
      detail: text,
      meta: %{action: action},
      log_level: :debug
    }
  end
end

defimpl AshPhoenix.FormData.Error, for: MishkaCmsCore.Accounts.AuthGate.Closed do
  def to_form_error(_error), do: []
end
