defmodule SurfaceEject.TemplateM3GoldenTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Template}
  alias SurfaceEject.Profiles

  @fixtures Path.expand("../fixtures", __DIR__)
  @ctx %Context{profile: Profiles.Bonfire.profile()}

  test "golden: group_view (surface_live_view page — blocks, :on-*, dynamic dispatch)" do
    {out, logs} = convert_fixture("group_view/input/group_live.sface")

    assert out == expected("group_view/expected/group_live.heex")
    # dynamic-dispatch call sites converted, so no unknown flags for them
    assert Enum.count(logs, &(&1.category == :unknown_component)) == 1
  end

  test "golden: form (Surface built-ins flagged, left unchanged)" do
    {out, logs} = convert_fixture("form/input/new_group_form_live.sface")

    assert out == expected("form/expected/new_group_form_live.heex")
    assert Enum.any?(logs, &(&1.category == :surface_builtin and &1.severity == :manual_required))
  end

  defp convert_fixture(rel) do
    path = Path.join(@fixtures, rel)
    Template.convert(File.read!(path), %{@ctx | file: path})
  end

  defp expected(rel), do: File.read!(Path.join(@fixtures, rel))
end
