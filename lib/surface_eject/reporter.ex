defmodule SurfaceEject.Reporter do
  @moduledoc """
  Renders a conversion run into the review artifacts: a human-first markdown report (errors and manual-review items with locations up top, info as counts, meant to be read alongside `git diff` when applying) and a per-file status map (persisted as `.surface_eject_status.json` to track incremental migration).
  """

  alias SurfaceEject.Runner

  @doc "The markdown report for a `Runner.plan/3` result."
  @spec markdown(%{binary => Runner.action()}, [struct]) :: binary
  def markdown(actions, logs) do
    changed = Enum.reject(actions, fn {_path, action} -> action == :unchanged end)

    """
    # Surface ejection report

    #{map_size(actions)} files planned, #{length(changed)} with changes.

    | severity | count |
    |---|---|
    #{severity_table(logs)}
    #{section("Errors", logs, :error)}
    #{section("Manual review required", logs, :manual_required)}
    #{section("Warnings", logs, :warning)}
    ## Info (counts)

    #{info_counts(logs)}

    ## Changed files

    #{file_list(changed)}
    """
  end

  @doc """
  Migration-tracking status: a summary plus ONLY the files where something happened (converted, renamed, errored), unchanged files are implicit, listing thousands of them would drown the signal.
  """
  def status(actions) do
    files =
      for {path, action} <- actions, action != :unchanged, into: %{} do
        {path,
         case action do
           {:write, _content, logs} -> %{action: :write, manual: manual_count(logs)}
           {:move, to, _content, logs} -> %{action: :move, to: to, manual: manual_count(logs)}
           {:error, _message, _logs} -> %{action: :error, manual: 0}
         end}
      end

    %{
      summary: %{
        planned: map_size(actions),
        changed: map_size(files),
        errors: Enum.count(files, fn {_path, entry} -> entry.action == :error end),
        manual: files |> Map.values() |> Enum.map(& &1.manual) |> Enum.sum()
      },
      files: files
    }
  end

  defp manual_count(logs), do: Enum.count(logs, &(&1.severity == :manual_required))

  defp severity_table(logs) do
    logs
    |> Enum.frequencies_by(& &1.severity)
    |> Enum.sort_by(fn {severity, _count} ->
      Enum.find_index([:error, :manual_required, :warning, :info], &(&1 == severity))
    end)
    |> Enum.map_join("\n", fn {severity, count} -> "| #{severity} | #{count} |" end)
  end

  defp section(title, logs, severity) do
    case Enum.filter(logs, &(&1.severity == severity)) do
      [] ->
        ""

      entries ->
        items =
          entries
          |> Enum.group_by(& &1.category)
          |> Enum.sort_by(fn {_category, list} -> -length(list) end)
          |> Enum.map_join("\n", fn {category, list} ->
            "### #{category} (#{length(list)})\n\n" <>
              Enum.map_join(list, "\n", fn log ->
                "- `#{log.file}#{if log.line, do: ":#{log.line}"}` — #{log.message}"
              end)
          end)

        "## #{title}\n\n#{items}\n"
    end
  end

  defp info_counts(logs) do
    logs
    |> Enum.filter(&(&1.severity == :info))
    |> Enum.frequencies_by(& &1.category)
    |> Enum.sort_by(fn {_category, count} -> -count end)
    |> Enum.map_join("\n", fn {category, count} -> "- #{category}: #{count}" end)
  end

  defp file_list(changed) do
    changed
    |> Enum.sort_by(fn {path, _action} -> path end)
    |> Enum.map_join("\n", fn
      {path, {:write, _content, _logs}} -> "- `#{path}`"
      {path, {:move, to, _content, _logs}} -> "- `#{path} → #{to}`"
      {path, {:error, message, _logs}} -> "- ⚠ `#{path}` — #{message}"
    end)
  end
end