defmodule SurfaceEject.TaskTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  defmodule CustomProfile do
    def profile, do: %SurfaceEject.Profile{use_atom_map: %{surface_thing: :plain_thing}}
  end

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

  test "--profile resolves a custom module exposing profile/0" do
    igniter =
      test_project(
        files: %{
          "lib/thing.ex" => """
          defmodule My.Thing do
            use My.Web, :surface_thing
          end
          """
        }
      )
      |> Igniter.compose_task("surface.eject", [
        "--path",
        "lib",
        "--profile",
        "SurfaceEject.TaskTest.CustomProfile"
      ])

    source =
      Enum.find(Rewrite.sources(igniter.rewrite), fn source ->
        Rewrite.Source.get(source, :path) == "lib/thing.ex"
      end)

    assert Rewrite.Source.get(source, :content) =~ "use My.Web, :plain_thing"
  end

  test "--profile with an unknown module raises a descriptive error" do
    assert_raise Mix.Error, ~r/--profile must be/, fn ->
      test_project()
      |> Igniter.compose_task("surface.eject", ["--profile", "No.Such.Module"])
    end
  end
end
