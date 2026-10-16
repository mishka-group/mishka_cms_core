# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ErrorPreviewConnTest do
  @moduledoc """
  What an error page's preview is given to render with, and what it says when it still cannot.

  An error page is the one document that is genuinely ABOUT the request: the seeded 500 template
  carries `<a href={@conn.request_path}>Try again</a>`, which is the correct thing for a live error
  page to do and the exact thing a preview has no request for. The stand-in conn was
  `%{assigns: %{current_site: site}}` and nothing else, so that template did not render at all —
  a preview whose whole job is to show the page showed a red box instead.

  The second half is what the red box SAID. `KeyError`'s message inspects the map it looked in, so
  the note published the whole `%Site{}` — id, host, allowed origins — into
  `/_preview/:resource/:token`, a page that takes no login because the token is the capability. A
  preview link handed to a designer is not a place to print the site's internals.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.ErrorPage
  alias MishkaCmsCore.Runtime.RuntimePreview

  defp record(template) do
    %{
      name: "errors",
      site: %{name: "localhost", id: "5f1f0a2e-0000-4000-8000-000000000001", host: "localhost"},
      root_layout_template: nil,
      error_pages: [%{status: 500, template: template, layout: %{}}]
    }
  end

  defp render(template), do: RuntimePreview.inner_html(record(template), ErrorPage, 500, nil)

  describe "the stand-in conn" do
    test "carries the request path an error page links back to" do
      html = render(~s|<a href={@conn.request_path}>Try again</a>|)

      assert html =~ "Try again"
      refute html =~ "Preview unavailable"
    end

    test "and the other fields a request-shaped template reads" do
      html =
        render(~s|<p>{@conn.method} {@conn.request_path}{@conn.query_string} {@conn.status}</p>|)

      refute html =~ "Preview unavailable"
      assert html =~ "GET"
      assert html =~ "500"
    end

    test "and still hands over the site, which components resolve through" do
      html = render(~s|<p>{@conn.assigns.current_site.name}</p>|)

      assert html =~ "localhost"
    end
  end

  describe "when it genuinely cannot render" do
    test "the note says what was missing without publishing what it looked in" do
      html = render(~s|<p>{@definitely_not_an_assign}</p>|)

      assert html =~ "Preview unavailable"

      refute html =~ "current_site",
             "the note printed the assigns map, and a preview link needs no login"

      refute html =~ "allowed_origins"
      refute html =~ "5f1f0a2e-0000-4000-8000-000000000001"
    end

    test "and still names the key, which is the half worth reading" do
      html = render(~s|<p>{@definitely_not_an_assign}</p>|)

      assert html =~ "definitely_not_an_assign"
    end
  end
end
