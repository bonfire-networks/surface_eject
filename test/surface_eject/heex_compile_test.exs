defmodule SurfaceEject.HeexCompileTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Template}

  # converted outputs must COMPILE as HEEx (and render, where no LV plumbing
  # is needed) against stub components — the end-to-end guarantee that the
  # emitted syntax is real HEEx, not just string-shaped
  @ctx %Context{
    type_map: %{
      "SurfaceEject.Test.Stubs.Card" => :function_component,
      "SurfaceEject.Test.Stubs.LC" => :live_component
    },
    aliases: %{"Card" => "SurfaceEject.Test.Stubs.Card", "LC" => "SurfaceEject.Test.Stubs.LC"}
  }

  defp compile_and_render(surface_source, assigns) do
    {heex, _logs} = Template.convert(surface_source, @ctx)

    module = :"SurfaceEject.CompileSmoke#{System.unique_integer([:positive])}"

    code = """
    defmodule #{module} do
      use Phoenix.Component

      # converted call sites keep ALIAS names — the module's alias lines must
      # survive conversion (`:compat` mode preserves them); mirror that here
      alias SurfaceEject.Test.Stubs.Card
      alias SurfaceEject.Test.Stubs.LC
      _ = {Card, LC}

      def render(var!(assigns)) do
        ~H\"\"\"
    #{heex}
        \"\"\"
      end
    end
    """

    [{mod, _} | _] = Code.compile_string(code)

    apply(mod, :render, [assigns])
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "converted blocks + function-component call compile and render" do
    html =
      compile_and_render(
        "{#if @show}{#for x <- @xs}<Card a={x} />{/for}{#else}none{/if}",
        %{show: true, xs: [1, 2], __changed__: nil}
      )

    assert html =~ "card:1"
    assert html =~ "card:2"

    assert compile_and_render(
             "{#if @show}x{#else}none{/if}",
             %{show: false, __changed__: nil}
           ) =~ "none"
  end

  test "converted case/match compiles and renders" do
    html =
      compile_and_render(
        "{#case @s}{#match :a}A{#match other}got {inspect(other)}{/case}",
        %{s: :b, __changed__: nil}
      )

    assert html =~ "got :b"
  end

  test "converted live_component call site compiles" do
    {heex, _} = Template.convert(~S(<LC id="x" />), @ctx)
    assert heex == ~S(<.live_component module={SurfaceEject.Test.Stubs.LC} id="x" />)

    # compile-only (rendering an LC needs LiveView plumbing)
    module = :"SurfaceEject.CompileSmokeLC#{System.unique_integer([:positive])}"

    code = """
    defmodule #{module} do
      use Phoenix.Component
      def render(var!(assigns)) do
        _ = var!(assigns)
        ~H\"\"\"
    #{heex}
        \"\"\"
      end
    end
    """

    assert [{_, _} | _] = Code.compile_string(code)
  end

  test "converted slot fallback compiles and renders" do
    html =
      compile_and_render(
        "<#slot {@side}>fallback</#slot>",
        %{side: nil, __changed__: nil}
      )

    assert html =~ "fallback"
  end
end
