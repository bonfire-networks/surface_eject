defmodule SurfaceEject.RuntimeTest do
  use ExUnit.Case, async: true

  doctest SurfaceEject.Runtime

  test "embed_colocated_template: template embedded + render_template/1 defined" do
    dir = Path.join(System.tmp_dir!(), "colocated_tpl_test")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sample_card.heex"), "<div>{@label}</div>\n")

    Code.compile_string(
      """
      defmodule SampleCard do
        use Phoenix.Component
        require SurfaceEject.Runtime
        SurfaceEject.Runtime.embed_colocated_template(root: "#{dir}")

        def render(assigns), do: render_template(assigns)
      end
      """,
      Path.join(dir, "sample_card.ex")
    )

    html =
      SampleCard.render(%{__changed__: nil, label: "hi"})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html == "<div>hi</div>"
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "colocated_tpl_test"))
  end
end
