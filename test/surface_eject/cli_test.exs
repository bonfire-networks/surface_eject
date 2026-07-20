defmodule SurfaceEject.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SurfaceEject.CLI

  @card_ex """
  defmodule My.Card do
    use Surface.Component

    prop a, :string

    def render(assigns), do: nil
  end
  """

  @page_sface "{#if @x}<Card a=\"1\" />{/if}"

  setup %{tmp_dir: tmp} do
    lib = Path.join(tmp, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, "card.ex"), @card_ex)

    File.write!(Path.join(lib, "page.ex"), """
    defmodule My.Page do
      use Surface.LiveView
      alias My.Card
    end
    """)

    File.write!(Path.join(lib, "page.sface"), @page_sface)
    {:ok, lib: lib}
  end

  defp tree_snapshot(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  @tag :tmp_dir
  test "dry run (the default) writes NOTHING — byte-identical tree", %{lib: lib} do
    before = tree_snapshot(lib)

    output = capture_io(fn -> CLI.main(["--path", lib]) end)

    assert tree_snapshot(lib) == before
    assert output =~ "Dry run — nothing written"
    assert output =~ "page.sface → "
  end

  @tag :tmp_dir
  test "--apply converts and renames", %{lib: lib} do
    capture_io(fn -> CLI.main(["--path", lib, "--apply"]) end)

    refute File.exists?(Path.join(lib, "page.sface"))
    heex = File.read!(Path.join(lib, "page.heex"))
    assert heex == "<%= if @x do %><Card.render a=\"1\" /><% end %>"

    # direct Surface use rewritten (generic default profile, :attr mode)
    assert File.read!(Path.join(lib, "page.ex")) =~ "use Phoenix.LiveView"
    assert File.read!(Path.join(lib, "card.ex")) =~ "attr :a, :string"
  end

  @tag :tmp_dir
  test "--profile accepts a .exs file evaluating to a %Profile{}", %{tmp_dir: tmp, lib: lib} do
    profile_path = Path.join(tmp, "my_profile.exs")

    File.write!(profile_path, """
    %SurfaceEject.Profile{declarations: :compat}
    """)

    capture_io(fn -> CLI.main(["--path", lib, "--profile", profile_path, "--apply"]) end)

    # compat: declarations untouched (only the use line rewritten)
    assert File.read!(Path.join(lib, "card.ex")) =~ "prop a, :string"
  end

  @tag :tmp_dir
  test "unknown profile raises a descriptive error", %{lib: lib} do
    assert_raise ArgumentError, ~r/--profile must be/, fn ->
      capture_io(fn -> CLI.main(["--path", lib, "--profile", "nope"]) end)
    end
  end

  @tag :tmp_dir
  test "--scan-path: types resolve from outside the convert path, scanned files untouched",
       %{tmp_dir: tmp} do
    # component lives in ext_b; only ext_a is converted
    ext_b = Path.join(tmp, "ext_b/lib")
    File.mkdir_p!(ext_b)

    File.write!(Path.join(ext_b, "widget.ex"), """
    defmodule Other.Widget do
      use Surface.Component

      prop a, :string

      def render(assigns), do: nil
    end
    """)

    ext_a = Path.join(tmp, "ext_a/lib")
    File.mkdir_p!(ext_a)

    File.write!(Path.join(ext_a, "page.ex"), """
    defmodule My.Page do
      use Surface.LiveView
      alias Other.Widget
    end
    """)

    File.write!(Path.join(ext_a, "page.sface"), "<Widget a=\"1\" />")

    scan_before = tree_snapshot(ext_b)

    capture_io(fn ->
      CLI.main(["--path", ext_a, "--scan-path", Path.join(tmp, "ext_b"), "--apply"])
    end)

    # resolved as a function component (not flagged unknown) thanks to the scan
    assert File.read!(Path.join(ext_a, "page.heex")) == "<Widget.render a=\"1\" />"
    # scan-only tree is never converted
    assert tree_snapshot(ext_b) == scan_before
  end

  @tag :tmp_dir
  test "deps/_build are excluded by default; --exclude adds more", %{tmp_dir: tmp, lib: lib} do
    for dir <- ["deps/some_dep", "_build/dev", "vendor"] do
      full = Path.join(lib, dir)
      File.mkdir_p!(full)
      File.write!(Path.join(full, "dep.sface"), "{#if @x}y{/if}")
    end

    output =
      capture_io(fn ->
        CLI.main(["--path", lib, "--exclude", "vendor", "--apply"])
      end)

    for dir <- ["deps/some_dep", "_build/dev", "vendor"] do
      assert File.read!(Path.join(lib, "#{dir}/dep.sface")) == "{#if @x}y{/if}"
      refute output =~ dir
    end

    # the real tree still converted
    assert File.exists?(Path.join(lib, "page.heex"))
    _ = tmp
  end
end
