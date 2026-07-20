defmodule SurfaceEject.ExGoldenTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Ex, Profile}

  @fixtures Path.expand("../fixtures", __DIR__)
  @compat Profile.bonfire()

  # inline-~F module (8 sigils) in :compat mode — reviewed snapshot
  # (generated once by the converter, human-reviewed, then pinned)
  test "compat golden: link_live.ex (inline ~F sigils)" do
    path = Path.join(@fixtures, "link_inline/input/link_live.ex")

    {out, logs} = Ex.convert(File.read!(path), %Context{profile: @compat, file: path})

    assert out == File.read!(Path.join(@fixtures, "link_inline/expected/link_live.ex"))
    refute out =~ "~F"
    # call sites unresolved or builtin-flagged only — nothing unexpected
    # (:default_slot_fallback is the standing caller-review advisory)
    assert Enum.all?(
             logs,
             &(&1.category in
                 [:unknown_component, :surface_builtin, :use_atom, :default_slot_fallback])
           )
  end

  # sface-colocated Bonfire modules in :compat mode: NO ~F, declarations
  # untouched — the ONLY delta is the one-token use-atom swap (Surface atom →
  # context-lib-wired plain macro atom), pinning the tiny-.ex-delta guarantee
  for name <- ~w(reusable_modal_live thread_live feed_live) do
    test "compat golden: #{name}.ex delta is only the use-atom swap" do
      path = Path.join(unquote(@fixtures), "compat_modules/input/#{unquote(name)}.ex")
      source = File.read!(path)

      {out, logs} = Ex.convert(source, %Context{profile: @compat, file: path})

      assert out ==
               File.read!(
                 Path.join(unquote(@fixtures), "compat_modules/expected/#{unquote(name)}.ex")
               )

      assert Enum.any?(logs, &(&1.category == :use_atom))
    end
  end
end
