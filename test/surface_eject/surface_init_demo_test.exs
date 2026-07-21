defmodule SurfaceEject.SurfaceInitDemoTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Profiles, Runner}

  @moduledoc """
  The default profile against the files `mix surface.init --demo` actually
  generates (copied from surface's own `priv/templates`, web module
  substituted) — the closest thing to a canonical stock-Surface project.
  """

  @fixtures Path.expand("../fixtures/surface_init_demo/input", __DIR__)

  setup_all do
    files =
      for f <- ~w(card.ex demo.ex), into: %{} do
        {"lib/#{f}", File.read!(Path.join(@fixtures, f))}
      end

    {actions, logs} = Runner.plan(files, Profiles.Default.profile())
    {:ok, actions: actions, logs: logs}
  end

  test "demo.ex: use-atom swap + call site + slot entries", %{actions: actions} do
    assert {:write, out, _} = actions["lib/demo.ex"]

    # the one web-macro atom surface.init patches in
    assert out =~ "use MyAppWeb, :live_view"
    # scanned alias resolves Card as a function component
    assert out =~ ~s(<Card.render max_width="lg" rounded>)
    assert out =~ "</Card.render>"
    # named slot entries are already valid HEEx — untouched
    assert out =~ "<:header>"
    assert out =~ "<:footer>"
    refute out =~ "~F"
  end

  test "card.ex: declarations + slots convert; @doc folds into doc:", %{actions: actions} do
    assert {:write, out, _} = actions["lib/card.ex"]

    assert out =~ "use Phoenix.Component"
    assert out =~ ~s|attr :rounded, :boolean, default: false, doc: "The background color"|
    assert out =~ ~s|attr :max_width, :string, values: ["sm", "md", "lg"], doc: "The max width|
    assert out =~ ~s|slot :header, doc: "The header slot"|
    assert out =~ ~s|slot :footer, doc: "The footer slot"|
    assert out =~ ~s|slot :inner_block, doc: "The main content slot"|
    assert out =~ "{render_slot(@header)}"
    assert out =~ "{render_slot(@inner_block)}"
    refute out =~ "~F"

    # Phoenix attr/slot do NOT consume @doc — left in place, the dangling
    # @doc would redefine repeatedly and wrongly document render/1
    refute out =~ ~s|@doc "The header slot"|
    refute out =~ ~s|@doc "The background color"|
  end

  test "class sugar without a css_class_helper wraps but WARNS (semantics differ)", %{
    logs: logs
  } do
    assert Enum.any?(
             logs,
             &(&1.category == :css_class_no_helper and &1.severity == :warning)
           )
  end

  test "card.ex compiles as plain Phoenix (after the flagged class attr was manually fixed)", %{
    actions: actions
  } do
    assert {:write, out, _} = actions["lib/card.ex"]

    # the flagged comma-list class expr is the ONE thing that can't compile
    # as-is; neutralize it the way the manual fix would and compile the rest
    out =
      String.replace(
        out,
        ~S|{"card", "max-w-#{@max_width}", "rounded-2xl": @rounded}|,
        ~S|{["card", "max-w-#{@max_width}", @rounded && "rounded-2xl"]}|
      )

    assert [{mod, _} | _] = Code.compile_string(out)
    assert function_exported?(mod, :render, 1)
  end
end
