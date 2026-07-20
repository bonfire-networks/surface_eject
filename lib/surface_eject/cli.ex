defmodule SurfaceEject.CLI do
  @moduledoc """
  The escript entrypoint — run the converter against any directory WITHOUT adding surface_eject as a dependency of the target project:

      mix escript.build
      ./surface_eject --profile bonfire --path ../my_app/lib            # dry-run (default)
      ./surface_eject --profile bonfire --path ../my_app/lib --apply    # write + rename

  Because the pipeline is pure source-text transformation (the scan parses sources with Sourceror, it never loads the target's modules), the escript does not compile or load the target project, a dry run only reads files and prints, while `--apply` is the only code path that writes.

  `--profile` accepts a built-in name (`default`, `bonfire`) or a path to a `.exs` file whose last expression evaluates to a `%SurfaceEject.Profile{}` (the no-dep equivalent of the mix task's custom profile module).

  `--scan-path` (repeatable) adds trees that are SCANNED for component types/aliases but never converted — convert one app of a multi-app project while resolving components defined in the others. `--exclude` (repeatable) adds path segments to skip on top of the defaults (deps, _build, node_modules).
  """

  alias SurfaceEject.{Files, Profile, Runner}

  def main(argv) do
    {opts, _, invalid} =
      OptionParser.parse(argv,
        strict: [
          profile: :string,
          path: :string,
          scan_path: :keep,
          exclude: :keep,
          apply: :boolean,
          verbose: :boolean,
          debug: :boolean
        ]
      )

    if invalid != [], do: raise(ArgumentError, "invalid options: #{inspect(invalid)}")

    path = opts[:path] || "lib"
    profile = profile!(opts[:profile])
    apply? = opts[:apply] || false
    debug? = opts[:debug] || false
    scan_paths = Keyword.get_values(opts, :scan_path)
    excludes = Keyword.get_values(opts, :exclude)

    status("Listing files (excluding: #{Enum.join(Files.default_excludes() ++ excludes, ", ")})…")

    {convert_paths, scan_only_paths} =
      [path | scan_paths]
      |> Enum.flat_map(&Files.list_files(&1, excludes))
      |> Files.partition(path, scan_paths, excludes)

    status(
      "#{length(convert_paths)} files to convert, #{length(scan_only_paths)} scan-only; scanning…"
    )

    read = &Map.new(&1, fn file -> {file, File.read!(file)} end)

    progress =
      if debug?,
        do: fn phase, file -> status("[#{phase}] #{file}") end,
        else: fn _phase, _file -> :ok end

    {actions, logs} =
      Runner.plan(read.(convert_paths), profile,
        scan_files: read.(scan_only_paths),
        progress: progress
      )

    report(actions, logs, opts[:verbose] || false)

    if apply?, do: apply_actions(actions), else: IO.puts("\nDry run — nothing written (pass --apply to convert).")
  end

  # liveness/progress goes to stderr so stdout stays a clean report
  defp status(message), do: IO.puts(:stderr, message)

  defp report(actions, logs, verbose?) do
    changed =
      for {file, action} <- Enum.sort(actions), action != :unchanged do
        case action do
          {:write, _content, _logs} -> IO.puts("convert  #{file}")
          {:move, new_path, _content, _logs} -> IO.puts("convert  #{file} → #{new_path}")
          {:error, message, _logs} -> IO.puts("ERROR    #{message}")
        end

        file
      end

    IO.puts("\n#{map_size(actions)} files planned, #{length(changed)} with changes")

    logs
    |> Enum.frequencies_by(& &1.severity)
    |> Enum.each(fn {severity, count} -> IO.puts("  #{severity}: #{count}") end)

    if verbose? do
      Enum.each(logs, fn log ->
        IO.puts("  [#{log.severity}] #{log.file}:#{log.line || "-"} #{log.message}")
      end)
    end
  end

  defp apply_actions(actions) do
    Enum.each(actions, fn
      {file, {:write, content, _logs}} ->
        File.write!(file, content)

      {file, {:move, new_path, content, _logs}} ->
        File.write!(file, content)
        File.rename!(file, new_path)

      {_file, _unchanged_or_error} ->
        :ok
    end)

    IO.puts("\nApplied. Review with git diff.")
  end

  defp profile!(name) do
    SurfaceEject.Profiles.builtin(name) || custom_profile!(name)
  end

  defp custom_profile!(path) do
    with true <- String.ends_with?(path, ".exs") and File.exists?(path),
         {%Profile{} = profile, _binding} <- Code.eval_file(path) do
      profile
    else
      _ ->
        raise ArgumentError,
              "--profile must be \"default\", \"bonfire\", or a path to a .exs file " <>
                "evaluating to a %SurfaceEject.Profile{} — got: #{path}"
    end
  end
end