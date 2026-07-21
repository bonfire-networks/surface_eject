defmodule SurfaceEject.ExGoldenTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Ex, Scan}
  alias SurfaceEject.Profiles

  @fixtures Path.expand("../fixtures", __DIR__)

  # ctx as Runner builds it: module + kind from the scan
  defp native_ctx(path) do
    profile = Profiles.Bonfire.profile()
    scan = Scan.scan_source(File.read!(path), %Context{profile: profile})

    %Context{
      profile: profile,
      module: scan.module,
      type_map: %{scan.module => scan.type},
      aliases: scan.aliases,
      file: path
    }
  end

  # inline-~F function component whose decls precede a 3-arity defp: props →
  # live_attr (attr would bind link_opts/3), slot + its @doc deleted, sigils
  # converted — reviewed snapshot
  test "native golden: link_live.ex (inline ~F sigils, non-adjacent → live_attr)" do
    path = Path.join(@fixtures, "link_inline/input/link_live.ex")

    {out, _logs} = Ex.convert(File.read!(path), native_ctx(path))

    assert out == File.read!(Path.join(@fixtures, "link_inline/expected/link_live.ex"))
    refute out =~ "~F"
    refute out =~ ~r/^\s*prop /m
    assert out =~ "live_attr :to, :string, required: true"
  end

  # sface-colocated live components: props → live_attr (reapply), data →
  # internal: true, doc strings folded — reviewed snapshots
  for name <- ~w(reusable_modal_live thread_live feed_live) do
    test "native golden: #{name}.ex (live component declarations → live_attr)" do
      path = Path.join(unquote(@fixtures), "compat_modules/input/#{unquote(name)}.ex")

      {out, _logs} = Ex.convert(File.read!(path), native_ctx(path))

      assert out ==
               File.read!(
                 Path.join(unquote(@fixtures), "compat_modules/expected/#{unquote(name)}.ex")
               )

      refute out =~ ~r/^\s*(prop|data) /m
    end
  end

  # :compat stays available for projects with their own macro layer: the
  # ONLY delta is the use-atom swap
  test "compat mode: delta is only the use-atom swap" do
    path = Path.join(@fixtures, "compat_modules/input/reusable_modal_live.ex")
    source = File.read!(path)

    compat = %{Profiles.Bonfire.profile() | declarations: :compat}
    {out, logs} = Ex.convert(source, %Context{profile: compat, file: path})

    assert out == String.replace(source, ":stateful_component", ":live_component")
    assert Enum.any?(logs, &(&1.category == :use_atom))
  end
end
