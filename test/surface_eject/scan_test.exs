defmodule SurfaceEject.ScanTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Profile, Scan}

  @bonfire %Context{profile: Profile.bonfire()}

  test "detects direct Surface use" do
    assert %{module: "My.Card", type: :function_component} =
             Scan.scan_source("defmodule My.Card do\n  use Surface.Component\nend", %Context{})

    assert %{type: :live_component} =
             Scan.scan_source("defmodule My.LC do\n  use Surface.LiveComponent\nend", %Context{})

    assert %{type: :live_view} =
             Scan.scan_source("defmodule My.LV do\n  use Surface.LiveView\nend", %Context{})
  end

  test "detects web-macro atoms via profile" do
    src = "defmodule My.Card do\n  use Bonfire.UI.Common.Web, :stateless_component\nend"
    assert %{type: :function_component} = Scan.scan_source(src, @bonfire)

    src = "defmodule My.LC do\n  use Bonfire.UI.Common.Web, :stateful_component\nend"
    assert %{type: :live_component} = Scan.scan_source(src, @bonfire)

    src = "defmodule My.LV do\n  use Bonfire.UI.Common.Web, :surface_live_view\nend"
    assert %{type: :live_view} = Scan.scan_source(src, @bonfire)
  end

  test "non-component modules scan with nil type" do
    assert %{type: nil} =
             Scan.scan_source("defmodule My.Util do\n  def a, do: 1\nend", %Context{})
  end

  test "collects file-local aliases (simple, multi, as:)" do
    src = """
    defmodule My.Card do
      use Surface.Component
      alias Some.Deep.Widget
      alias Other.{A, B}
      alias Long.Name, as: Short
    end
    """

    %{aliases: aliases} = Scan.scan_source(src, %Context{})
    assert aliases["Widget"] == "Some.Deep.Widget"
    assert aliases["A"] == "Other.A"
    assert aliases["B"] == "Other.B"
    assert aliases["Short"] == "Long.Name"
  end

  test "build/1 merges scans into a type map" do
    sources = [
      "defmodule My.Card do\n  use Surface.Component\nend",
      "defmodule My.LC do\n  use Surface.LiveComponent\nend",
      "defmodule My.Util do\nend"
    ]

    scans = Enum.map(sources, &Scan.scan_source(&1, %Context{}))
    type_map = Scan.build(scans)

    assert type_map == %{"My.Card" => :function_component, "My.LC" => :live_component}
  end
end
