defmodule MishkaCmsCore.Runtime.Resources.Validations.TenantContextTest do
  @moduledoc """
  The gate every master and tenant action goes through.

  A master action runs only for a master: a user whose `site_id` is nil. Nobody else is one — not a
  missing actor, not an actor with no `site_id` at all, not a site user holding `*`. A tenant action
  runs only with a tenant, and a site user only with its own site as the tenant. A master may act on
  any site. A call made with `authorize?: false` is a system call and is not checked.
  """
  use MishkaCmsCore.DataCase

  alias MishkaCmsCore.Accounts.{Permission, User}
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Runtime.Layout

  require Ash.Query
  alias MishkaCmsCore.Runtime.Resources.Validations.TenantContext

  @master [require_master: true]
  @tenant [require_master: false]

  defp context(tenant, actor, authorize?),
    do: %Ash.Resource.Validation.Context{tenant: tenant, actor: actor, authorize?: authorize?}

  # The query and changeset a real action hands the validation: the refusal names their resource
  # and action.
  defp query, do: %{Ash.Query.new(User) | action: Ash.Resource.Info.action(User, :tenant_read)}

  defp changeset,
    do: %{Ash.Changeset.new(User) | action: Ash.Resource.Info.action(User, :tenant_update)}

  defp validate(opts, tenant, actor, authorize? \\ true),
    do: TenantContext.validate(query(), opts, context(tenant, actor, authorize?))

  defp atomic(opts, tenant, actor, authorize? \\ true),
    do: TenantContext.atomic(changeset(), opts, context(tenant, actor, authorize?))

  defp site_user(site_id), do: %{id: Ash.UUID.generate(), site_id: site_id}
  defp master, do: %{id: Ash.UUID.generate(), site_id: nil}

  describe "a master action" do
    test "runs for a master" do
      assert :ok = validate(@master, nil, master())
      assert :ok = atomic(@master, nil, master())
    end

    test "does not run with no actor, refused as a policy refuses" do
      assert {:error, %Ash.Error.Forbidden.Policy{} = error} = validate(@master, nil, nil)
      assert Exception.message(error) =~ "requires a master user"
      assert {:error, %Ash.Error.Forbidden.Policy{}} = atomic(@master, nil, nil)
    end

    test "does not run for an actor that has no site_id at all" do
      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               validate(@master, nil, %{id: Ash.UUID.generate()})

      assert {:error, %Ash.Error.Forbidden.Policy{}} =
               atomic(@master, nil, %{id: Ash.UUID.generate()})
    end

    test "does not run for a site user, who is sent to the tenant action" do
      assert {:error, message: message} = validate(@master, nil, site_user(Ash.UUID.generate()))
      assert message =~ "requires a master user"

      assert {:error, %Ash.Error.Changes.InvalidChanges{}} =
               atomic(@master, nil, site_user(Ash.UUID.generate()))
    end

    test "does not run with a tenant, even for a master" do
      assert {:error, message: message} = validate(@master, Ash.UUID.generate(), master())
      assert message =~ "Tenant context must be nil"
    end

    test "a system call is not checked" do
      assert :ok = validate(@master, nil, nil, false)
      assert :ok = atomic(@master, nil, nil, false)
      assert :ok = atomic(@master, Ash.UUID.generate(), site_user(Ash.UUID.generate()), false)
    end
  end

  describe "a tenant action" do
    test "runs for a site user on its own site" do
      site_id = Ash.UUID.generate()

      assert :ok = validate(@tenant, site_id, site_user(site_id))
      assert :ok = atomic(@tenant, site_id, site_user(site_id))
    end

    test "does not run for a site user on another site" do
      actor = site_user(Ash.UUID.generate())
      other_site = Ash.UUID.generate()

      assert {:error, %Ash.Error.Forbidden.Policy{} = error} =
               validate(@tenant, other_site, actor)

      assert Exception.message(error) =~ "A site user can act only on their own site."

      assert {:error, %Ash.Error.Forbidden.Policy{} = error} = atomic(@tenant, other_site, actor)
      assert Exception.message(error) =~ "A site user can act only on their own site."
    end

    test "runs for a master on any site" do
      assert :ok = validate(@tenant, Ash.UUID.generate(), master())
      assert :ok = atomic(@tenant, Ash.UUID.generate(), master())
    end

    test "runs for a visitor with no actor, on the site it visits" do
      assert :ok = validate(@tenant, Ash.UUID.generate(), nil)
    end

    test "does not run without a tenant, with the error Ash gives for a missing one" do
      for actor <- [site_user(Ash.UUID.generate()), master(), nil] do
        assert {:error, %Ash.Error.Invalid.TenantRequired{resource: User}} =
                 validate(@tenant, nil, actor)

        assert {:error, %Ash.Error.Invalid.TenantRequired{resource: User}} =
                 atomic(@tenant, nil, actor)
      end
    end

    test "a system call is not checked" do
      assert :ok = validate(@tenant, Ash.UUID.generate(), site_user(Ash.UUID.generate()), false)
    end
  end

  describe "a refusal" do
    setup do
      policies = Application.get_env(:ash, :policies)
      on_exit(fn -> Application.put_env(:ash, :policies, policies) end)
      {:ok, policies: policies}
    end

    test "reads as its own message where policy breakdowns are shown" do
      assert Application.get_env(:ash, :policies)[:show_policy_breakdowns?]

      refusals = [
        validate(@tenant, Ash.UUID.generate(), site_user(Ash.UUID.generate())),
        atomic(@tenant, Ash.UUID.generate(), site_user(Ash.UUID.generate())),
        validate(@master, nil, nil),
        atomic(@master, nil, nil)
      ]

      for {:error, %Ash.Error.Forbidden.Policy{} = error} <- refusals do
        message = Exception.message(error)

        assert String.starts_with?(message, "A site user can act only on their own site.") or
                 String.starts_with?(message, "This action requires a master user")

        refute message =~ "CondClauseError"
        assert error.resource == User
      end

      assert length(refusals) == 4
    end

    test "is returned, not raised, where policy breakdowns are logged", %{policies: policies} do
      Application.put_env(
        :ash,
        :policies,
        Keyword.put(policies || [], :log_policy_breakdowns, :error)
      )

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          validate(@tenant, Ash.UUID.generate(), site_user(Ash.UUID.generate()))
        end)

      assert {:error, %Ash.Error.Forbidden.Policy{}} = result
      assert log =~ "MishkaCmsCore.Accounts.User.tenant_read"
    end
  end

  describe "through real actions" do
    setup do
      site_a = create_site!()
      site_b = create_site!()

      {:ok,
       site_a: site_a,
       site_b: site_b,
       star_a: create_user_with_permissions!(["*"], site_id: site_a.id),
       user_b: create_user!(site_id: site_b.id),
       master: create_user_with_permissions!(["*"])}
    end

    test "a site user holding * reads its own site's users through the tenant action", ctx do
      assert {:ok, %{results: users}} =
               User
               |> Ash.Query.for_read(:tenant_read, %{}, actor: ctx.star_a, tenant: ctx.site_a.id)
               |> Ash.read()

      assert Enum.all?(users, &(&1.site_id == ctx.site_a.id))
    end

    test "a site user holding * cannot pass another site as the tenant", ctx do
      assert {:error, %Ash.Error.Forbidden{} = error} =
               User
               |> Ash.Query.for_read(:tenant_read, %{}, actor: ctx.star_a, tenant: ctx.site_b.id)
               |> Ash.read()

      assert Exception.message(error) =~ "A site user can act only on their own site."

      assert {:error, _} =
               Ash.get(User, ctx.user_b.id,
                 action: :tenant_get,
                 actor: ctx.star_a,
                 tenant: ctx.site_b.id
               )
    end

    test "a master reads another site's users through the tenant action", ctx do
      assert {:ok, %{results: users}} =
               User
               |> Ash.Query.for_read(:tenant_read, %{}, actor: ctx.master, tenant: ctx.site_b.id)
               |> Ash.read()

      assert ctx.user_b.id in Enum.map(users, & &1.id)
    end

    test "a master action built with no actor is refused, whoever runs it", ctx do
      assert {:error, %Ash.Error.Forbidden{} = error} =
               Permission
               |> Ash.Changeset.for_create(:create, %{name: "made:by:nobody"})
               |> Ash.create(actor: ctx.star_a)

      assert Exception.message(error) =~ "requires a master user"
    end
  end

  describe "a site user's permissions hold on its own site, whoever built the input" do
    # This validation reads the actor an input was BUILT with. The permission check every resource's
    # policy asks reads the one it RUNS with, and a site user holds its permissions on its own site
    # only: under another site's tenant it holds none of them.
    setup do
      site_a = create_site!()
      site_b = create_site!()

      {:ok,
       site_a: site_a,
       site_b: site_b,
       star_a: create_user_with_permissions!(["*"], site_id: site_a.id),
       master: create_user_with_permissions!(["*"]),
       layout_a: create_layout!(site_id: site_a.id),
       layout_b: create_layout!(site_id: site_b.id)}
    end

    defp read_layout(layout, build_opts, run_opts) do
      Layout
      |> Ash.Query.for_read(:get_with_versions, %{}, build_opts)
      |> Ash.Query.filter(id == ^layout.id)
      |> Ash.read_one(run_opts)
    end

    defp describe_layout(layout, build_opts, run_opts) do
      layout
      |> Ash.Changeset.for_update(:update, %{description: "written from elsewhere"}, build_opts)
      |> Ash.update(run_opts)
    end

    defp stored_description(layout),
      do: Ash.get!(Layout, layout.id, action: :read_any, authorize?: false).description

    test "another site's record is not read through an input built with no actor", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               read_layout(ctx.layout_b, [tenant: ctx.site_b.id],
                 actor: ctx.star_a,
                 tenant: ctx.site_b.id
               )
    end

    test "another site's record is not written through an input built with no actor", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               describe_layout(ctx.layout_b, [tenant: ctx.site_b.id], actor: ctx.star_a)

      refute stored_description(ctx.layout_b) == "written from elsewhere"
    end

    test "nor through an input built with a master's actor", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               describe_layout(ctx.layout_b, [actor: ctx.master, tenant: ctx.site_b.id],
                 actor: ctx.star_a
               )

      refute stored_description(ctx.layout_b) == "written from elsewhere"
    end

    test "its own site's record is read and written, however the input was built", ctx do
      assert {:ok, %{id: id}} =
               read_layout(ctx.layout_a, [tenant: ctx.site_a.id],
                 actor: ctx.star_a,
                 tenant: ctx.site_a.id
               )

      assert id == ctx.layout_a.id

      assert {:ok, _} =
               describe_layout(ctx.layout_a, [tenant: ctx.site_a.id], actor: ctx.star_a)

      assert stored_description(ctx.layout_a) == "written from elsewhere"
    end

    test "a master reads and writes any site's record", ctx do
      assert {:ok, %{id: id}} =
               read_layout(ctx.layout_b, [actor: ctx.master, tenant: ctx.site_b.id],
                 actor: ctx.master,
                 tenant: ctx.site_b.id
               )

      assert id == ctx.layout_b.id

      assert {:ok, _} =
               describe_layout(ctx.layout_b, [actor: ctx.master, tenant: ctx.site_b.id],
                 actor: ctx.master
               )
    end

    test "the permission check answers the same outside a policy", ctx do
      star = ["*"]

      refute AccessPermissions.match?(
               ctx.star_a,
               %{subject: Ash.Query.set_tenant(Ash.Query.new(Layout), ctx.site_b.id)},
               permissions: star
             )

      assert AccessPermissions.match?(
               ctx.star_a,
               %{subject: Ash.Query.set_tenant(Ash.Query.new(Layout), ctx.site_a.id)},
               permissions: star
             )

      assert AccessPermissions.match?(ctx.star_a, %{}, permissions: star)

      assert AccessPermissions.match?(
               ctx.master,
               %{subject: Ash.Query.set_tenant(Ash.Query.new(Layout), ctx.site_b.id)},
               permissions: star
             )
    end
  end

  describe "a master's action is a master's, whoever built the input" do
    # The run-time twin of this validation's master half: a site user holds no permission for an
    # action that declares `require_master: true`, so an input a master or a system call built gets
    # it nowhere.
    setup do
      site_b = create_site!()
      layout_b = create_layout!(site_id: site_b.id)

      {:ok,
       star_a: create_user_with_permissions!(["*"], site_id: create_site!().id),
       master: create_user_with_permissions!(["*"]),
       layout_b: Ash.get!(Layout, layout_b.id, action: :master_get, authorize?: false)}
    end

    defp master_read_ids(build_opts, run_opts) do
      Layout
      |> Ash.Query.for_read(:master_read, %{}, build_opts)
      |> Ash.read(Keyword.put(run_opts, :page, limit: 100))
      |> case do
        {:ok, %{results: layouts}} -> {:ok, Enum.map(layouts, & &1.id)}
        {:error, error} -> {:error, error}
      end
    end

    defp master_describe(layout, build_opts, run_opts) do
      layout
      |> Ash.Changeset.for_update(:master_update, %{description: "written by a site"}, build_opts)
      |> Ash.update(run_opts)
    end

    defp stored_layout_description(layout),
      do: Ash.get!(Layout, layout.id, action: :master_get, authorize?: false).description

    test "a site user reads nothing through a master's read a master built", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               master_read_ids([actor: ctx.master], actor: ctx.star_a)
    end

    test "a site user writes nothing through a master's update a master built", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               master_describe(ctx.layout_b, [actor: ctx.master], actor: ctx.star_a)

      refute stored_layout_description(ctx.layout_b) == "written by a site"
    end

    test "nor through one built as a system call", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               master_describe(ctx.layout_b, [authorize?: false],
                 actor: ctx.star_a,
                 authorize?: true
               )

      refute stored_layout_description(ctx.layout_b) == "written by a site"
    end

    test "a master reads and writes through them", ctx do
      assert {:ok, ids} = master_read_ids([actor: ctx.master], actor: ctx.master)
      assert ctx.layout_b.id in ids

      assert {:ok, _} = master_describe(ctx.layout_b, [actor: ctx.master], actor: ctx.master)
      assert stored_layout_description(ctx.layout_b) == "written by a site"
    end

    test "an action is a master's when it declares require_master: true" do
      assert TenantContext.requires_master?(Layout, :master_read)
      assert TenantContext.requires_master?(Layout, :master_update)
      assert TenantContext.requires_master?(User, :master_get)
      refute TenantContext.requires_master?(Layout, :read)
      refute TenantContext.requires_master?(Layout, :update)
      refute TenantContext.requires_master?(User, :tenant_read)
      refute TenantContext.requires_master?(Layout, nil)
    end
  end
end
