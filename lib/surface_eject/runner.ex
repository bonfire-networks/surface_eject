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

  alias SurfaceEject.{Context, Ex, Profile, Scan, Template}

  @type action ::
          {:write, content :: binary, logs :: list}
          | {:move, new_path :: binary, content :: binary, logs :: list}
          | :unchanged

  @doc "Returns `{%{path => action}, all_logs}`."
  def plan(files, %Profile{} = profile) when is_map(files) do
    base_ctx = %Context{profile: profile}

    scans =
      for {path, content} <- files, Path.extname(path) == ".ex", into: %{} do
        {path, Scan.scan_source(content, base_ctx)}
      end

    type_map = scans |> Map.values() |> Scan.build()

    actions =
      Map.new(files, fn {path, content} ->
        {path, plan_file(path, content, scans, type_map, profile)}
      end)

    logs =
      Enum.flat_map(actions, fn
        {_path, {:write, _content, logs}} -> logs
        {_path, {:move, _new, _content, logs}} -> logs
        _ -> []
      end)

    {actions, logs}
  end

  defp plan_file(path, content, scans, type_map, profile) do
    case Path.extname(path) do
      ".ex" ->
        ctx = ctx_for(path, scans[path], type_map, profile)
        {out, logs} = Ex.convert(content, ctx)
        if out == content and logs == [], do: :unchanged, else: {:write, out, logs}

      ".sface" ->
        # templates resolve through their colocated module's alias scope
        sibling = Path.rootname(path) <> ".ex"
        ctx = ctx_for(path, scans[sibling], type_map, profile)
        {out, logs} = Template.convert(content, ctx)
        {:move, Path.rootname(path) <> ".heex", out, logs}

      _ ->
        :unchanged
    end
  end

  defp ctx_for(path, scan, type_map, profile) do
    file_aliases = (scan && scan.aliases) || %{}

    %Context{
      profile: profile,
      type_map: type_map,
      aliases: file_aliases,
      file: path
    }
  end
end
