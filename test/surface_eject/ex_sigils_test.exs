defmodule SurfaceEject.ExSigilsTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Ex}

  defp convert(source, ctx \\ %Context{}) do
    {out, _logs} = Ex.convert(source, ctx)
    out
  end

  defp convert_logs(source, ctx \\ %Context{}) do
    {_out, logs} = Ex.convert(source, ctx)
    logs
  end

  test "render_surface (Surface.LiveViewTest) modules are left whole and flagged" do
    # the ~F only exists inside Surface's own test macro, so renaming it to ~H neither compiles (no sigil_H import) nor means anything to render_surface
    source = ~S'''
    defmodule My.Testing.Helpers do
      use Surface.LiveViewTest

      def render_stateless(component, assigns) do
        render_surface do
          ~F"""
          <StatelessComponent module={@component} />
          """
        end
      end
    end
    '''

    assert convert(source) == source

    assert Enum.any?(
             convert_logs(source),
             &(&1.category == :render_surface and &1.severity == :manual_required)
           )
  end

  test "~F heredoc becomes ~H with converted template" do
    source = ~S'''
    def render(assigns) do
      ~F"""
      {#if @x}A{/if}
      """
    end
    '''

    expected = ~S'''
    def render(assigns) do
      ~H"""
      <%= if @x do %>A<% end %>
      """
    end
    '''

    assert convert(source) == expected
  end

  test "single-line ~F delimiter forms" do
    assert convert(~S|def render(assigns), do: ~F"{!-- c --}"|) ==
             ~S|def render(assigns), do: ~H"<%!-- c --%>"|

    assert convert(~S|def a(assigns), do: ~F[{#if @x}A{/if}]|) ==
             ~S|def a(assigns), do: ~H[<%= if @x do %>A<% end %>]|

    assert convert(~S|def a(assigns), do: ~F(<div {...@opts}>x</div>)|) ==
             ~S|def a(assigns), do: ~H(<div {@opts}>x</div>)|

    # the empty template (blank stub renders)
    assert convert(~S|def render(assigns), do: ~F""|) ==
             ~S|def render(assigns), do: ~H""|
  end

  test "multiple sigils in one file all convert" do
    source = ~s(~F"""\n{!-- a --}\n"""\ndef x, do: 1\n~F"""\n{!-- b --}\n"""\n)
    out = convert(source)
    refute out =~ "~F"
    assert out =~ "<%!-- a --%>"
    assert out =~ "<%!-- b --%>"
  end

  test "template logs propagate from sigil bodies" do
    source = ~s(~F"""\n<div :hook="X">y</div>\n"""\n)
    assert Enum.any?(convert_logs(source), &(&1.category == :hook))
  end

  test "files without ~F pass through untouched" do
    source = "defmodule A do\n  def b, do: :c\nend\n"
    assert convert(source) == source
  end
end
