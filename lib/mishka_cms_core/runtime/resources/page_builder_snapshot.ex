# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilderSnapshot do
  @moduledoc """
  The document a history row can restore — gzipped HEEx, in a table of its own.

  Split from `MishkaCmsCore.Runtime.PageBuilderEvent` on a measurement rather than a preference.
  Postgres only moves a value out of the row past ~2 kB, and a typical snapshot is around 1.3 kB, so
  keeping it on the event row left it INLINE: 1,638 bytes of heap per row against 122, thirteen times
  the heap the timeline's own query walks on every page it draws.

  ## Why HEEx and not the tree

  The editor's tree is 5.5–12.7× the size of the HEEx it came from, and a compressed tree is still
  2.3–4.5× a gzipped HEEx while costing 3–5× the CPU to produce. `Serializer.to_heex/1` already runs
  on every save, so gzipping its output adds a few percent to work already being done, where encoding
  the tree adds ten to fifteen.

  ## What a round trip loses

  Node ids. They are minted fresh by every `Tree.parse/1`, so a restored document is structurally and
  stylistically identical and its ids are new. Anything that must survive a restore anchors by
  `Tree.address/2` instead — the same answer `MishkaCmsCore.Runtime.PageComment` reached when it hit
  this first.

  ## Refusal

  A document past `max_bytes/0` gets no snapshot at all: the event row is still written and simply
  cannot be reverted into, which the timeline says out loud. Storing a multi-megabyte payload on a
  path that runs while somebody is typing is the wrong trade, and replay was rejected for making
  every restore depend on every earlier row staying correct forever.
  """
  use Ash.Resource,
    otp_app: :mishka_cms_core,
    domain: MishkaCmsCore.Runtime,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # 1.4 MB of HEEx, past which no snapshot is taken. Measured: the largest real document in this
  # repo is 82 kB, so this is roughly seventeen times the biggest thing anyone has actually built.
  @max_bytes 1_400_000

  # FOUR TIMES THAT FOR THE ASSISTANT'S OWN ROWS. One prompt is a hundred edits the author never made
  # individually, so it is the change least reconstructible by hand and the worst one to leave
  # without a way back — which makes it the only row worth paying more for.
  #
  # The price is not storage. Markup gzips about 250×, so even 5.6 MB is tens of kilobytes on disk;
  # measured, compressing it costs ~20 ms. The price is the RESTORE, at roughly a second per megabyte
  # to un-gzip and re-parse, and that is why `MishkaCmsCore.Runtime.PageBuilder.History.revert/3` is
  # called off the LiveView rather than on it.
  #
  # It is only ever reached on a document already past the general cap — a page that costs seconds to
  # open at all — so it adds no class of problem that page did not already have.
  @ai_max_bytes @max_bytes * 4

  @doc """
  Largest HEEx a snapshot will be taken of, in bytes, for a change made by `author_type`.

  The assistant's rows are allowed a bigger document than anybody else's; see the note above
  `@ai_max_bytes`.
  """
  @spec max_bytes(atom() | nil) :: pos_integer()
  def max_bytes(:ai), do: @ai_max_bytes
  def max_bytes(_author_type), do: @max_bytes

  postgres do
    table "page_builder_snapshots"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    # The payload is the reason this table exists — keep it out of the main heap unconditionally
    # rather than at Postgres' own 2 kB discretion.
    custom_statements do
      statement :external_storage,
        up: "ALTER TABLE page_builder_snapshots ALTER COLUMN payload SET STORAGE EXTERNAL",
        down: "ALTER TABLE page_builder_snapshots ALTER COLUMN payload SET STORAGE EXTENDED"
    end
  end

  @doc """
  Compress a document for storage, or refuse it for being too large.

  Returns `{:ok, payload, byte_size}` or `:too_large`. The size recorded is the ORIGINAL's, because
  that is the number a threshold is about and the compressed length says nothing useful to a reader.
  """
  # NO DEFAULT. The cap depends on who made the change — an assistant's rows are allowed four times
  # everybody else's — so a caller that omitted it would silently get the general one, which is
  # exactly the case the larger cap exists for.
  @spec compress(String.t(), pos_integer()) :: {:ok, binary(), non_neg_integer()} | :too_large
  def compress(heex, max) when is_binary(heex) do
    case byte_size(heex) do
      size when size > max -> :too_large
      size -> {:ok, :zlib.gzip(heex), size}
    end
  end

  def compress(_heex, _max), do: :too_large

  @doc "The document back, or `:error` when the payload will not decompress."
  @spec decompress(binary()) :: {:ok, String.t()} | :error
  def decompress(payload) when is_binary(payload) do
    {:ok, :zlib.gunzip(payload)}
  rescue
    _error -> :error
  end

  def decompress(_payload), do: :error

  actions do
    default_accept [:payload, :byte_size]

    defaults [:read]

    # CREATE
    create :create do
      primary? true
      description "Stores one compressed document for a history row."
    end

    # DESTROY
    destroy :destroy do
      primary? true
      description "Drops the payload, leaving its event row readable but no longer revertible."
    end
  end

  policies do
    # Never reached by a person: written by the editor's flush and read by Revert, both of which run
    # under the actor whose editor is open.
    # A snapshot names no document type, so it takes any name that opens a builder; the history row
    # that points at it is held to its own type.
    policy action_type([:create, :read, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:runtime:page",
                      "admin:dashboard:runtime:layout",
                      "admin:dashboard:runtime:component",
                      "admin:dashboard:runtime:error_page",
                      "admin:dashboard:code"
                    ]}
    end

    # A SNAPSHOT HAS NO SITE, so nothing on it can hold a site user to their own. It is read through
    # the history row that points at it — and that row is held to the reader's site — or by a master
    # (`site_id` nil). Deleting one directly is a master's alone; a publish and the orphan sweep drop
    # payloads as the system.
    policy action_type(:read) do
      authorize_if accessing_from(MishkaCmsCore.Runtime.PageBuilderEvent, :snapshot)
      authorize_if actor_attribute_equals(:site_id, nil)
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :payload, :binary do
      allow_nil? false
      public? true
      description "The document, gzipped HEEx"
    end

    attribute :byte_size, :integer do
      allow_nil? false
      public? true
      description "Size of the ORIGINAL document, before compression"
    end

    create_timestamp :inserted_at
  end
end
