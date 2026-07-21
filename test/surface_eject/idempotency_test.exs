defmodule SurfaceEject.IdempotencyTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Ex, Profile, Runner}
  alias SurfaceEject.Profiles

  @moduledoc """
  Re-running the converter over already-converted output must be a byte-exact
  no-op (the plan's re-run guard): `~H` bodies are never touched, swapped use
  atoms no longer match the map, `attr`/`slot :name` declarations aren't
  Surface declarations, and `.heex` files aren't planned at all.
  """

  @fixtures Path.expand("../fixtures", __DIR__)

  test "native-mode converted module converts to itself" do
    path = Path.join(@fixtures, "link_inline/expected/link_live.ex")
    converted = File.read!(path)

    profile = Profiles.Bonfire.profile()
    scan = SurfaceEject.Scan.scan_source(converted, %Context{profile: profile})

    ctx = %Context{
      profile: profile,
      module: scan.module,
      type_map: %{scan.module => scan.type},
      file: path
    }

    {out, logs} = Ex.convert(converted, ctx)

    assert out == converted
    assert logs == []
  end

  test "attr-mode converted module converts to itself" do
    source = """
    defmodule Idem.Comp do
      use Surface.Component

      prop label, :string, default: "x"

      slot default
      slot side

      def render(assigns) do
        ~F"<b>{@label}</b>"
      end
    end
    """

    ctx = %Context{profile: %Profile{declarations: :attr}}
    {converted, _} = Ex.convert(source, ctx)
    {reconverted, logs} = Ex.convert(converted, ctx)

    assert reconverted == converted
    assert logs == []
  end

  test "re-planning a converted tree is all :unchanged" do
    files = %{
      "lib/card.ex" => """
      defmodule My.Card do
        use Surface.Component

        prop a, :string

        def render(assigns), do: nil
      end
      """,
      "lib/page.ex" => """
      defmodule My.Page do
        use Bonfire.UI.Common.Web, :surface_live_view
        alias My.Card
      end
      """,
      "lib/page.sface" => "{#if @x}<Card a=\"1\" />{/if}"
    }

    {actions, _} = Runner.plan(files, Profiles.Bonfire.profile())

    # apply the plan the way the task would (writes + .sface → .heex rename)
    converted_tree =
      Map.new(actions, fn
        {path, {:write, content, _}} -> {path, content}
        {path, {:move, new_path, content, _}} when path != new_path -> {new_path, content}
        {path, :unchanged} -> {path, files[path]}
      end)

    {actions2, logs2} = Runner.plan(converted_tree, Profiles.Bonfire.profile())

    assert Enum.all?(actions2, fn {_path, action} -> action == :unchanged end),
           "expected all :unchanged, got: #{inspect(actions2)}"

    assert logs2 == []
  end
end