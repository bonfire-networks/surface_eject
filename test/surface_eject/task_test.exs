defmodule SurfaceEject.TaskTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  test "task converts a small project tree (virtual FS composition)" do
    igniter =
      test_project(
        files: %{
          "lib/card.ex" => """
          defmodule My.Card do
            use Surface.Component

            prop a, :string

            def render(assigns), do: nil
          end
          """,
          "lib/page.ex" => """
          defmodule My.Page do
            use Surface.LiveView
            alias My.Card
          end
          """,
          "lib/page.sface" => "{#if @x}<Card /> {!-- c --}{/if}"
        }
      )
      |> Igniter.compose_task("surface.eject", ["--path", "lib"])

    # sface converted; rename recorded (moves map or repathed source)
    source =
      Enum.find(Rewrite.sources(igniter.rewrite), fn source ->
        Rewrite.Source.get(source, :path) in ["lib/page.heex", "lib/page.sface"]
      end)

    assert source, "converted template source not found"
    content = Rewrite.Source.get(source, :content)
    assert content =~ "<%= if @x do %>"
    assert content =~ "<Card.render />"
    assert content =~ "<%!-- c --%>"

    assert Rewrite.Source.get(source, :path) == "lib/page.heex" or
             igniter.moves["lib/page.sface"] == "lib/page.heex"
  end
end
