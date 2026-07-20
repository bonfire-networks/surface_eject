defmodule SurfaceEject.Runner do
  @moduledoc """
  The pure planning core of the conversion pipeline: given file contents and a
  profile, produce per-file actions. The Igniter mix task is a thin shell that
  gathers files, calls `plan/2`, and applies the actions through Igniter (for
  dry-run/diff/confirmation).

  Two phases, as one call:

    1. SCAN all `.ex` files → per-module types + aliases → project type map.
    2. CONVERT: `.ex` through `SurfaceEject.Ex`, `.sface` through
       `SurfaceEject.Template` (with the COLOCATED module's aliases — a
       template resolves component names through its module's alias scope),
       renamed to `.heex`.
  """

  alias SurfaceEject.{Context, Ex, LogEntry, Profile, Scan, Template}

  @type action ::
          {:write, content :: binary, logs :: list}
          | {:move, new_path :: binary, content :: binary, logs :: list}
          | {:error, message :: binary, logs :: list}
          | :unchanged

  @doc """
  Returns `{%{path => action}, all_logs}`.

  Options:

    * `:scan_files` — additional `%{path => content}` map scanned for the
      project type map (types + aliases) but NEVER converted — lets a run
      convert one app of a multi-app tree while resolving components defined
      in the others.
    * `:progress` — `fn phase, path -> ... end` called per file with phase
      `:scan` | `:convert` (for frontends to show liveness).
  """
  def plan(files, %Profile{} = profile, opts \\ []) when is_map(files) do
    base_ctx = %Context{profile: profile}
    progress = Keyword.get(opts, :progress, fn _phase, _path -> :ok end)

    # a file that fails to parse must not kill the run: its scan is dropped
    # (and its conversion below becomes an {:error, _, _} action)
    scans =
      for {path, content} <- Map.merge(Keyword.get(opts, :scan_files, %{}), files),
          Path.extname(path) == ".ex",
          into: %{} do
        progress.(:scan, path)

        {path,
         try do
           Scan.scan_source(content, base_ctx)
         rescue
           e -> {:scan_error, Exception.message(e)}
         end}
      end

    type_map =
      scans
      |> Map.values()
      |> Enum.reject(&match?({:scan_error, _}, &1))
      |> Scan.build()

    actions =
      Map.new(files, fn {path, content} ->
        progress.(:convert, path)
        {path, plan_file(path, content, scans, type_map, profile)}
      end)

    logs =
      Enum.flat_map(actions, fn
        {_path, {:write, _content, logs}} -> logs
        {_path, {:move, _new, _content, logs}} -> logs
        {_path, {:error, _message, logs}} -> logs
        _ -> []
      end)

    {actions, logs}
  end

  defp plan_file(path, content, scans, type_map, profile) do
    case Path.extname(path) do
      ".ex" ->
        case scans[path] do
          {:scan_error, message} ->
            error_action(path, message)

          scan ->
            ctx = ctx_for(path, scan, type_map, profile)

            try do
              {out, logs} = Ex.convert(content, ctx)
              if out == content and logs == [], do: :unchanged, else: {:write, out, logs}
            rescue
              e -> error_action(path, Exception.message(e))
            end
        end

      ".sface" ->
        # templates resolve through their colocated module's alias scope
        # (a sibling that failed to scan degrades to no aliases; its own
        # error is reported on the sibling)
        sibling = Path.rootname(path) <> ".ex"
        ctx = ctx_for(path, scans[sibling], type_map, profile)

        try do
          {out, logs} = Template.convert(content, ctx)
          {:move, Path.rootname(path) <> ".heex", out, logs}
        rescue
          e -> error_action(path, Exception.message(e))
        end

      _ ->
        :unchanged
    end
  end

  defp error_action(path, message) do
    message = "#{path}: left unchanged, conversion failed: #{message}"

    {:error, message,
     [%LogEntry{phase: :runner, severity: :error, file: path, message: message}]}
  end

  defp ctx_for(path, scan, type_map, profile) do
    file_aliases =
      case scan do
        %{aliases: aliases} -> aliases
        _ -> %{}
      end

    %Context{
      profile: profile,
      type_map: type_map,
      aliases: file_aliases,
      file: path
    }
  end
end
