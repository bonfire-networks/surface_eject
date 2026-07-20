defmodule SurfaceEject.SurfaceInteropTest do
  use ExUnit.Case, async: false

  alias SurfaceEject.{Context, Ex, Profile}

  @moduledoc """
  The incremental-migration direction the equivalence harness doesn't cover:
  an UNCONVERTED Surface `~F` caller rendering a CONVERTED plain function
  component through the dotted tag (`<Comp.render>`), the same call-site
  shape the converter emits. Verifies Surface's `AST.FunctionComponent`
  path end-to-end — attrs, defaults, default slot content, and (the
  previously-unverified question) NAMED slot entries crossing from `~F`
  into a plain `Phoenix.Component` slot.
  """

  defp converted_component(mod) do
    source = """
    defmodule #{mod} do
      use Surface.Component

      prop show, :boolean, default: false
      prop label, :string, default: "default-label"

      slot default
      slot side

      def render(assigns) do
        ~F\"\"\"
          <div>
            {#if @show}yes{#else}no{/if}
            <b>{@label}</b>
            <#slot />
            <#slot {@side} />
          </div>
        \"\"\"
      end
    end
    """

    {converted, _logs} = Ex.convert(source, %Context{profile: %Profile{declarations: :attr}})
    Code.compile_string(converted)
  end

  defp render_surface_caller(caller_body) do
    n = System.unique_integer([:positive])
    comp = "SurfaceEject.Interop#{n}.Comp"
    converted_component(comp)

    wrapper = "SurfaceEject.Interop#{n}.Wrap"

    Code.compile_string("""
    defmodule #{wrapper} do
      use Surface.Component
      alias #{comp}, as: Comp

      def render(assigns) do
        ~F\"\"\"
          #{caller_body}
        \"\"\"
      end
    end
    """)

    Module.concat([wrapper]).render(%{__changed__: nil, __context__: %{}})
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "~F caller renders a converted function component (attrs + defaults)" do
    html = render_surface_caller(~S(<Comp.render show label="hi" />))

    assert html =~ "yes"
    assert html =~ "<b>hi</b>"
  end

  test "~F caller passes default slot content to a converted component" do
    html = render_surface_caller(~S(<Comp.render><u>body</u></Comp.render>))

    assert html =~ "no"
    assert html =~ "<b>default-label</b>"
    assert html =~ "<u>body</u>"
  end

  test "~F caller passes NAMED slot entries to a converted component" do
    html =
      render_surface_caller(
        ~S(<Comp.render label="x"><u>body</u><:side><s>side!</s></:side></Comp.render>)
      )

    assert html =~ "<u>body</u>"
    assert html =~ "<s>side!</s>"
  end
end
