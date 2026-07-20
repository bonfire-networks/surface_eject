defmodule SurfaceEject.ReporterTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{LogEntry, Reporter}

  defp log(severity, category, file, line, message) do
    %LogEntry{
      phase: :template,
      severity: severity,
      category: category,
      file: file,
      line: line,
      message: message
    }
  end

  defp actions, do: %{
    "lib/a.ex" => {:write, "new", [log(:info, :use_atom, "lib/a.ex", 2, "swapped")]},
    "lib/a.sface" =>
      {:move, "lib/a.heex", "conv",
       [log(:manual_required, :surface_builtin, "lib/a.sface", 5, "Field left unchanged")]},
    "lib/b.ex" => :unchanged,
    "lib/broken.ex" => {:error, "boom", [log(:error, :runner, "lib/broken.ex", nil, "boom")]}
  }

  defp logs, do: [
    log(:info, :use_atom, "lib/a.ex", 2, "swapped"),
    log(:manual_required, :surface_builtin, "lib/a.sface", 5, "Field left unchanged"),
    log(:error, :runner, "lib/broken.ex", nil, "boom")
  ]

  test "markdown report: summary, errors, manual sections; info as counts" do
    md = Reporter.markdown(actions(), logs())

    assert md =~ "# Surface ejection report"
    assert md =~ "4 files planned"
    assert md =~ "3 with changes"

    # errors are prominent
    assert md =~ "## Errors"
    assert md =~ "boom"

    # manual items listed with location
    assert md =~ "## Manual review required"
    assert md =~ "lib/a.sface:5"
    assert md =~ "Field left unchanged"

    # info only as counts, not line-by-line
    assert md =~ "use_atom: 1"
    refute md =~ "swapped"

    # converted files listed with their action
    assert md =~ "lib/a.sface → lib/a.heex"
  end

  test "status: summary + only files where something happened" do
    status = Reporter.status(actions())

    assert status.summary == %{planned: 4, changed: 3, errors: 1, manual: 1}
    assert status.files["lib/a.ex"] == %{action: :write, manual: 0}
    assert status.files["lib/a.sface"] == %{action: :move, to: "lib/a.heex", manual: 1}
    assert status.files["lib/broken.ex"] == %{action: :error, manual: 0}
    # unchanged files are implicit — no entry
    refute Map.has_key?(status.files, "lib/b.ex")
  end
end
