defmodule SurfaceEject.RunnerTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.Runner
  alias SurfaceEject.Profiles

  @card_ex """
  defmodule My.Card do
    use Surface.Component

    prop a, :string

    def render(assigns), do: nil
  end
  """

  @page_ex """
  defmodule My.Page do
    use Bonfire.UI.Common.Web, :surface_live_view
    alias My.Card
  end
  """

  @page_sface "{#if @x}<Card a=\"1\" />{/if}"

  @util_ex "defmodule My.Util do\n  def a, do: 1\nend\n"

  test "plans a small tree: scan feeds call-site conversion via sibling aliases" do
    files = %{
      "lib/card.ex" => @card_ex,
      "lib/page.ex" => @page_ex,
      "lib/page.sface" => @page_sface,
      "lib/util.ex" => @util_ex
    }

    {actions, _logs} = Runner.plan(files, Profiles.Bonfire.profile())

    # untouched module
    assert actions["lib/util.ex"] == :unchanged

    # page.ex: use-atom swap only (compat)
    assert {:write, page_out, _} = actions["lib/page.ex"]
    assert page_out =~ "use Bonfire.UI.Common.Web, :live_view"

    # sface converted with sibling's alias resolving Card → My.Card (function component)
    assert {:move, "lib/page.heex", sface_out, _} = actions["lib/page.sface"]
    assert sface_out == "<%= if @x do %><Card.render a=\"1\" /><% end %>"
  end

  # one bad file must not kill the whole run: it becomes an {:error, _, _}
  # action (with an :error-severity log) and every other file still converts
  test "a file that fails to parse is isolated, the rest of the plan proceeds" do
    files = %{
      "lib/card.ex" => @card_ex,
      "lib/page.ex" => @page_ex,
      "lib/page.sface" => @page_sface,
      # truncated tag — Surface tokenizer raises
      "lib/broken.sface" => "<div class=",
      # syntax error — Sourceror raises during scan
      "lib/broken.ex" => "defmodule My.Broken do\n  def a, do:\n"
    }

    {actions, logs} = Runner.plan(files, Profiles.Bonfire.profile())

    assert {:error, msg, [%{severity: :error}]} = actions["lib/broken.sface"]
    assert msg =~ "broken.sface"

    assert {:error, _msg, [%{severity: :error}]} = actions["lib/broken.ex"]

    # healthy files still planned
    assert {:write, _, _} = actions["lib/page.ex"]
    assert {:move, "lib/page.heex", _, _} = actions["lib/page.sface"]

    # error logs surface in the combined log list
    assert Enum.count(logs, &(&1.severity == :error)) == 2
  end
end
