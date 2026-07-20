defmodule SurfaceEject.FilesTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.Files

  @tag :tmp_dir
  test "list_files prunes excluded/dot/symlinked dirs during traversal", %{tmp_dir: tmp} do
    for dir <- ["lib/nested", "deps/dep_a", "node_modules/pkg", "vendor", ".git"] do
      full = Path.join(tmp, dir)
      File.mkdir_p!(full)
      File.write!(Path.join(full, "mod.ex"), "defmodule X, do: nil")
    end

    File.write!(Path.join(tmp, "lib/page.sface"), "x")
    File.write!(Path.join(tmp, "lib/other.txt"), "not convertible")

    # symlink cycle: must not hang or follow
    File.ln_s!(tmp, Path.join(tmp, "lib/loop"))

    found = tmp |> Files.list_files(["vendor"]) |> Enum.map(&Path.relative_to(&1, tmp)) |> Enum.sort()

    assert found == ["lib/nested/mod.ex", "lib/page.sface"]
  end
end