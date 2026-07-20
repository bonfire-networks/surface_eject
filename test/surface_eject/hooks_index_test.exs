defmodule SurfaceEject.HooksIndexTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.HooksIndex

  @moduledoc """
  The Surface-independent hook collector: Surface's compiler generated
  `hooks/index.js` from modules still using Surface — converted modules
  silently dropped out. This collector globs colocated `*.hooks.js`,
  resolves each module from the sibling `.ex`, and regenerates the SAME
  artifact (module-named copies + ns()-namespaced index), so hook names and
  bundler wiring stay untouched across the whole migration.
  """

  setup %{tmp_dir: tmp} do
    a = Path.join(tmp, "ext_a/lib/comp")
    File.mkdir_p!(a)
    File.write!(Path.join(a, "lazy.ex"), "defmodule My.Lazy do\nend\n")
    File.write!(Path.join(a, "lazy.hooks.js"), "export default { mounted() {} }\n")

    b = Path.join(tmp, "ext_b/lib/x")
    File.mkdir_p!(b)
    File.write!(Path.join(b, "thing.ex"), "defmodule My.B.Thing do\nend\n")
    File.write!(Path.join(b, "thing.hooks.js"), "export const Fancy = { mounted() {} }\n")

    # orphan without a sibling module — skipped, reported
    File.write!(Path.join(b, "orphan.hooks.js"), "export default {}\n")

    {:ok, out: Path.join(tmp, "out/hooks")}
  end

  @tag :tmp_dir
  test "copies module-named hooks + generates the ns index", %{tmp_dir: tmp, out: out} do
    {:ok, result} = HooksIndex.generate([Path.join(tmp, "ext_a"), Path.join(tmp, "ext_b")], out)

    assert result.copied == ["My.B.Thing", "My.Lazy"]
    assert [orphan] = result.skipped
    assert orphan =~ "orphan.hooks.js"

    assert File.read!(Path.join(out, "My.Lazy.hooks.js")) =~ "mounted()"

    index = File.read!(Path.join(out, "index.js"))
    assert index =~ ~s(import * as c1 from "./My.B.Thing.hooks.js")
    assert index =~ ~s(import * as c2 from "./My.Lazy.hooks.js")
    assert index =~ ~s{ns(c1, "My.B.Thing")}
    assert index =~ "let hooks = Object.assign("
    assert index =~ "export default hooks"
  end

  @tag :tmp_dir
  test "the hooks-index escript subcommand", %{tmp_dir: tmp, out: out} do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        SurfaceEject.CLI.main([
          "hooks-index",
          "--path",
          Path.join(tmp, "ext_a"),
          "--path",
          Path.join(tmp, "ext_b"),
          "--out",
          out
        ])
      end)

    assert output =~ "2 hooks collected"
    assert output =~ "orphan.hooks.js"
    assert File.exists?(Path.join(out, "index.js"))
  end
end
