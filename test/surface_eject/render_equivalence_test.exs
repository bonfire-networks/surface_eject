defmodule SurfaceEject.RenderEquivalenceTest do
  use ExUnit.Case, async: false

  alias SurfaceEject.{Context, Ex, Profile, Template}

  @moduledoc """
  The semantic guarantee tier: the ORIGINAL Surface component and its
  CONVERTED plain-LV counterpart must render the SAME DOM for the same
  assigns. Each case compiles both sides from source (a component definition
  + a caller template), renders with identical assigns, and compares
  Floki-normalized HTML.

  Self-contained synthetic components only (real-project components need
  their app's helpers — their equivalence check is the project's own test
  suite before/after conversion).
  """

  # component body is parameterized by module name (per side, per case)
  defp component_source(mod) do
    """
    defmodule #{mod} do
      use Surface.Component

      prop show, :boolean, default: false
      prop items, :list, default: []
      prop label, :string, default: "default-label"

      slot default
      slot side

      def render(assigns) do
        ~F\"\"\"
        <div>
          {#if @show}yes{#else}no{/if}
          {#for x <- @items}<i>{x}</i>{#else}<em>empty</em>{/for}
          <b>{@label}</b>
          <#slot>fallback</#slot>
          <#slot {@side} />
        </div>
        \"\"\"
      end
    end
    """
  end

  defp surface_html(caller_tpl, assigns) do
    n = System.unique_integer([:positive])
    comp = "SurfaceEject.EqS#{n}.Comp"
    Code.compile_string(component_source(comp))

    wrapper = "SurfaceEject.EqS#{n}.Wrap"

    Code.compile_string("""
    defmodule #{wrapper} do
      use Surface.Component
      alias #{comp}, as: Comp

      prop a, :map, default: %{}

      def render(assigns) do
        ~F\"\"\"
        #{caller_tpl}
        \"\"\"
      end
    end
    """)

    render(wrapper, assigns)
  end

  defp converted_html(caller_tpl, assigns) do
    n = System.unique_integer([:positive])
    comp = "SurfaceEject.EqC#{n}.Comp"

    {conv_comp, _} =
      Ex.convert(component_source(comp), %Context{profile: %Profile{declarations: :attr}})

    Code.compile_string(conv_comp)

    {conv_tpl, _} =
      Template.convert(caller_tpl, %Context{
        profile: Profile.bonfire(),
        type_map: %{comp => :function_component},
        aliases: %{"Comp" => comp}
      })

    wrapper = "SurfaceEject.EqC#{n}.Wrap"

    Code.compile_string("""
    defmodule #{wrapper} do
      use Phoenix.Component
      alias #{comp}, as: Comp
      _ = Comp

      def render(var!(assigns)) do
        _ = var!(assigns)
        ~H\"\"\"
    #{conv_tpl}
        \"\"\"
      end
    end
    """)

    render(wrapper, assigns)
  end

  defp render(module, assigns) do
    mod = Module.concat([module])
    assigns = Map.merge(%{__changed__: nil, __context__: %{}, a: %{}}, assigns)

    apply(mod, :render, [assigns])
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp normalize(html), do: html |> Floki.parse_fragment!() |> Floki.raw_html()

  defp assert_equivalent(caller_tpl, assigns) do
    s = surface_html(caller_tpl, assigns)
    c = converted_html(caller_tpl, assigns)

    assert normalize(s) == normalize(c),
           "render divergence for #{inspect(assigns)}\n--- surface ---\n#{s}\n--- converted ---\n#{c}"
  end

  test "defaults + empty branches (falsy if, empty for-else, slot fallbacks)" do
    assert_equivalent(~S(<Comp />), %{})
  end

  test "truthy if, populated for, prop override" do
    assert_equivalent(~S(<Comp show items={[1, 2]} label="hi" />), %{})
  end

  test "default slot content overrides fallback" do
    assert_equivalent(~S(<Comp><u>inner</u></Comp>), %{})
  end

  test "named slot entry renders through <#slot {@side}>" do
    assert_equivalent(~S(<Comp><:side><s>side!</s></:side></Comp>), %{})
  end
end
