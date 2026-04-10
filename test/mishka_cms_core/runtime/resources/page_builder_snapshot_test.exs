defmodule MishkaCmsCore.Runtime.Resources.PageBuilderSnapshotTest do
  @moduledoc """
  The document a Revert puts back: what is kept, what is refused for size, and why the assistant's
  limit is not everybody else's.

  The threshold is measured against the ORIGINAL, not the compressed payload. Markup gzips about
  250×, so a limit on the stored bytes would be a limit on how repetitive the markup is rather than
  on how big the document is — and the number a reader is told would mean nothing.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilderSnapshot

  @moduletag :unit

  describe "max_bytes/1" do
    test "the assistant is allowed a bigger document than anybody else" do
      assert PageBuilderSnapshot.max_bytes(:ai) > PageBuilderSnapshot.max_bytes(:human)
    end

    test "everybody else is one number, whatever they are called" do
      general = PageBuilderSnapshot.max_bytes(:human)

      assert PageBuilderSnapshot.max_bytes(:system) == general
      assert PageBuilderSnapshot.max_bytes(nil) == general
    end
  end

  describe "compress/2" do
    test "keeps a document under the limit, and reports the ORIGINAL's size" do
      heex = String.duplicate("<p>hello</p>", 100)

      assert {:ok, payload, size} =
               PageBuilderSnapshot.compress(heex, PageBuilderSnapshot.max_bytes(:human))

      assert size == byte_size(heex)
      assert byte_size(payload) < size, "the payload should be compressed"
      assert {:ok, ^heex} = PageBuilderSnapshot.decompress(payload)
    end

    test "refuses a document over the limit it was given" do
      heex = String.duplicate("x", 2_000)

      assert :too_large = PageBuilderSnapshot.compress(heex, 1_000)
      assert {:ok, _payload, 2_000} = PageBuilderSnapshot.compress(heex, 2_000)
    end

    test "the limit is exact, not approximate" do
      heex = String.duplicate("x", 1_000)

      assert {:ok, _payload, 1_000} = PageBuilderSnapshot.compress(heex, 1_000)
      assert :too_large = PageBuilderSnapshot.compress(heex, 999)
    end

    test "a document the general limit refuses, the assistant's keeps" do
      # Only the length matters here, so this is built rather than parsed.
      heex = String.duplicate("y", PageBuilderSnapshot.max_bytes(:human) + 1)

      assert :too_large =
               PageBuilderSnapshot.compress(heex, PageBuilderSnapshot.max_bytes(:human))

      assert {:ok, _payload, _size} =
               PageBuilderSnapshot.compress(heex, PageBuilderSnapshot.max_bytes(:ai))
    end

    test "and the assistant's limit is still a limit" do
      heex = String.duplicate("z", PageBuilderSnapshot.max_bytes(:ai) + 1)

      assert :too_large = PageBuilderSnapshot.compress(heex, PageBuilderSnapshot.max_bytes(:ai))
    end

    test "anything that is not a document is refused rather than stored" do
      assert :too_large = PageBuilderSnapshot.compress(nil, PageBuilderSnapshot.max_bytes(:human))
      assert :too_large = PageBuilderSnapshot.compress(%{}, PageBuilderSnapshot.max_bytes(:human))
    end
  end

  describe "decompress/1" do
    test "a payload that will not decompress is reported, not raised" do
      assert :error = PageBuilderSnapshot.decompress("not a gzip stream at all")
    end

    test "round-trips a document exactly, whitespace and all" do
      heex = ~s(<div id="root">\n  <h1>Title</h1>\n  <p>hello  there</p>\n</div>\n)

      {:ok, payload, _size} =
        PageBuilderSnapshot.compress(heex, PageBuilderSnapshot.max_bytes(:human))

      assert {:ok, ^heex} = PageBuilderSnapshot.decompress(payload)
    end
  end
end
