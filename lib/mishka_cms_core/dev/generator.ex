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

  def component(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaCmsCore.Runtime.Component,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Component #{&1}"),
        # A TEMPLATE THAT READS AN ASSIGN THIS FACTORY NEVER DECLARES CANNOT RENDER. `attrs` below
        # is `[]`, so `@content` was a `KeyError` in every fixture component that was actually
        # drawn — caught by the canvas's `contain/3` and logged as "raised while rendering", which
        # made a rescued fixture defect look like a component failure and put noise in every run
        # that happened to draw one.
        template: "<div>Test template</div>",
        format: :heex,
        priority: 0,
        extra: %{},
        body: nil,
        attrs: [],
        slots: [],
        helpers: [],
        permissions: [],
        active: true,
        # EVERY BOOLEAN THIS RESOURCE HAS, PINNED. An attribute a generator says nothing about is
        # INVENTED by `Ash.Generator` from its type, and for a boolean that is a coin flip on every
        # fixture — so `precompile` and `required` have been random in every component this factory
        # ever built, and a fixture that happened to come out `precompile: true` compiles at boot.
        # Nothing asserted on either, so it stayed invisible until `stateful` arrived and a test
        # asked what a plain component's shape was.
        #
        # The page, layout and error-page factories beside this one all pin `precompile: false`. This
        # one was simply missed.
        precompile: false,
        required: false,
        stateful: false,
        description: nil,
        type: nil,
        examples: [],
        dependencies: [],
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
