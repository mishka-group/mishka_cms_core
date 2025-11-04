defmodule MishkaCmsCore.Dev.Generator do
  @moduledoc """
  Generator for MishkaCmsCore resources.
  - Test functions (no prefix): simple, deterministic — used by factory and tests.

  ## Every attribute an action accepts is named

  One a generator leaves out is INVENTED by `Ash.Generator` from its type, and a type is looser than
  the resource: a layout's `example` drawn from all of printable Unicode passes `min_length: 3` and
  is refused by the guard, which strips zero-width and control characters before counting, so seeds
  failed now and then. The same omission made `precompile` a coin flip and `uploads` a random list
  before it. `MishkaCmsCore.Dev.GeneratorNamesEveryAttributeTest` reads each `defaults` list against
  its action's `accept`, so an attribute added to a resource fails there first.
  """
  use Ash.Generator

  # ---------------------------------------------------------------------------
  # TEST generators (used by factory / tests)
  # ---------------------------------------------------------------------------

  def site(opts \\ []) do
    changeset_generator(
      MishkaCmsCore.Runtime.Site,
      :create,
      authorize?: false,
      defaults: [
        host: sequence(:host, &"test#{&1}.com"),
        name: sequence(:name, &"Test Site #{&1}"),
        active: true,
        priority: 0,
        master: false,
        # `:hybrid`, not one of the three at random. `mode` decides whether a site answers the web,
        # the API, or both, so a random one made every test touching either a coin flip — and while
        # the plugs compared this atom against a string and never matched, nothing noticed. A test
        # that wants another mode asks for it.
        mode: :hybrid,
        frontend_domain: nil,
        allowed_origins: []
      ],
      overrides: opts
    )
  end

  def layout(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.Layout,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Layout #{&1}"),
        path: sequence(:path, &"/test-path-#{&1}"),
        description: nil,
        template: "<html><head><title>Test</title></head><body><%= @content %></body></html>",
        format: :heex,
        priority: 0,
        extra: %{},
        content: %{},
        example: nil,
        resource_links: [],
        seo_tags: [],
        helpers: [],
        active: true,
        precompile: false,
        permissions: [],
        site_id: nil
      ],
      # A SEED IS NOT AN AUTHOR. These four resources carry `helpers` (and a page carries `events`
      # and `infos` too), and `Validations.CodeChange` refuses those from a write with no actor. A
      # seed and a test fixture have no actor at all, so they announce what they are the same way the
      # kit installer does.
      context: %{page_code: :package},
      overrides: opts,
      tenant: tenant
    )
  end

  def user(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Accounts.User,
      :register_with_password,
      authorize?: false,
      defaults: [
        email: sequence(:email, &"user#{&1}@example.com"),
        password: "Password123!",
        password_confirmation: "Password123!"
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def permission(opts \\ []) do
    changeset_generator(
      MishkaCmsCore.Accounts.Permission,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"permission:#{&1}"),
        description: sequence(:description, &"Test permission #{&1}")
      ],
      overrides: opts
    )
  end
end
