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

  alias SurfaceEject.{Files, Profile, Reporter, Runner}

  def main(["hooks-index" | argv]) do
    {opts, _, invalid} =
      OptionParser.parse(argv, strict: [path: :keep, out: :string])

    if invalid != [], do: raise(ArgumentError, "invalid options: #{inspect(invalid)}")

    roots = Keyword.get_values(opts, :path)
    out = opts[:out]

    if roots == [] or out == nil,
      do: raise(ArgumentError, "hooks-index requires --path (repeatable) and --out")

    {:ok, %{copied: copied, skipped: skipped}} = SurfaceEject.HooksIndex.generate(roots, out)

    IO.puts("#{length(copied)} hooks collected into #{out}/index.js")
    Enum.each(skipped, &IO.puts("skipped (no sibling module): #{&1}"))
  end

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
          debug: :boolean,
          report: :string,
          status_json: :string,
          out: :string
        ]
      )

    if invalid != [], do: raise(ArgumentError, "invalid options: #{inspect(invalid)}")

    path = opts[:path] || "lib"
    profile = profile!(opts[:profile])
    apply? = opts[:apply] || false
    debug? = opts[:debug] || false
    scan_paths = Keyword.get_values(opts, :scan_path)
    out_dir = opts[:out]

    # an --out dump nested inside the source tree must not be scanned
    excludes =
      Keyword.get_values(opts, :exclude) ++
        if out_dir, do: [Path.basename(out_dir)], else: []

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

    md = Reporter.markdown(actions, logs)
    IO.puts(md)
    if opts[:verbose], do: verbose_logs(logs)

    # dry runs write NOTHING unless a report/status path is explicitly requested
    if report_path = opts[:report] do
      File.mkdir_p!(Path.dirname(report_path))
      File.write!(report_path, md)
    end

    # the per-file status map is now OPTIONAL (write-only, never read back — the
    # converter re-plans from source each run; it's a dup-ish machine view of the
    # report for external incremental tooling). Only written when `--status-json PATH`
    # is given, on dry-run or apply — mirroring `--report`.
    if status_json = opts[:status_json] do
      File.mkdir_p!(Path.dirname(status_json))
      File.write!(status_json, Jason.encode!(Reporter.status(actions), pretty: true))
    end

    # --out: dump would-be outputs (renames applied) as a tree relative to
    # --path — droppable under lib/ or added to elixirc_paths to try compiling
    if out_dir && not apply?, do: dump(actions, path, out_dir)

    if apply? do
      apply_actions(actions)
      # the apply-review artifact, meant to be read alongside `git diff`
      unless opts[:report], do: File.write!(Path.join(path, "SURFACE_EJECT_REPORT.md"), md)
    else
      IO.puts("\nDry run — nothing written (pass --apply to convert).")
    end
  end

  defp verbose_logs(logs) do
    IO.puts("\n## All log lines\n")

    Enum.each(logs, fn log ->
      IO.puts("  [#{log.severity}] #{log.file}:#{log.line || "-"} #{log.message}")
    end)
  end

  # liveness/progress goes to stderr so stdout stays a clean report
  defp status(message), do: IO.puts(:stderr, message)

  defp dump(actions, path_root, out_dir) do
    Enum.each(actions, fn
      {file, {:write, content, _logs}} -> dump_file(out_dir, path_root, file, content)
      {_file, {:move, new_path, content, _logs}} -> dump_file(out_dir, path_root, new_path, content)
      {_file, _other} -> :ok
    end)

    status("Converted files dumped to #{out_dir}/")
  end

  defp dump_file(out_dir, path_root, file, content) do
    target = Path.join(out_dir, Path.relative_to(file, path_root))
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
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