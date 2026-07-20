defmodule Mix.Tasks.Surface.Eject do
  @shortdoc "Migrate Surface components/templates to plain Phoenix LiveView/HEEx"

  @moduledoc """
  #{@shortdoc}.

      mix surface.eject [--profile bonfire] [--path lib] [--dry-run]

  Igniter-powered: composes all changes and shows a diff before applying
  (`--dry-run` to only show it). Scans `.ex` files under `--path` for
  component types and aliases, converts `.ex` (declarations per profile +
  `~F` sigils) and `.sface` templates (renamed to `.heex`).

  Profiles: `default` (generic), `bonfire`, or the name of a module in your
  project exposing `profile/0` that returns a `%SurfaceEject.Profile{}`
  (e.g. `--profile MyApp.EjectProfile`). See `SurfaceEject.Profile`.
  """

  use Igniter.Mix.Task

  alias SurfaceEject.{Profile, Runner}

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :surface_eject,
      example: "mix surface.eject --profile bonfire --path lib --dry-run",
      schema: [profile: :string, path: :string, scan_path: :keep, exclude: :keep],
      defaults: [profile: "default", path: "lib"]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    profile = profile!(opts[:profile])
    path = opts[:path] || "lib"
    scan_paths = list_opt(opts, :scan_path)

    # read through Igniter's virtual FS (works with Igniter.Test projects too)
    igniter =
      Enum.reduce([path | scan_paths], igniter, fn root, igniter ->
        Igniter.include_glob(igniter, Path.join(root, "**/*.{ex,sface}"))
      end)

    contents =
      Map.new(Rewrite.sources(igniter.rewrite), fn source ->
        {Rewrite.Source.get(source, :path), Rewrite.Source.get(source, :content)}
      end)

    {convert_paths, scan_only_paths} =
      SurfaceEject.Files.partition(Map.keys(contents), path, scan_paths, list_opt(opts, :exclude))

    {actions, logs} =
      Runner.plan(Map.take(contents, convert_paths), profile,
        scan_files: Map.take(contents, scan_only_paths)
      )

    igniter =
      Igniter.create_new_file(
        igniter,
        Path.join(path, "SURFACE_EJECT_REPORT.md"),
        SurfaceEject.Reporter.markdown(actions, logs),
        on_exists: :overwrite
      )

    Enum.reduce(actions, igniter, fn
      {file, {:write, content, _logs}}, igniter ->
        update(igniter, file, content)

      {file, {:move, new_path, content, _logs}}, igniter ->
        igniter
        |> update(file, content)
        |> Igniter.move_file(file, new_path)

      {_file, {:error, message, _logs}}, igniter ->
        Igniter.add_warning(igniter, "surface.eject: #{message}")

      {_file, :unchanged}, igniter ->
        igniter
    end)
  end

  defp update(igniter, path, content) do
    Igniter.update_file(igniter, path, fn source ->
      Rewrite.Source.update(source, :content, fn _ -> content end)
    end)
  end

  # :keep options arrive as a scalar when passed once, a list when repeated
  defp list_opt(opts, key), do: opts |> Keyword.get_values(key) |> List.flatten()

  defp profile!(name) do
    SurfaceEject.Profiles.builtin(name) || custom_profile!(name)
  end

  defp custom_profile!(module_name) do
    module = Igniter.Project.Module.parse(module_name)

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :profile, 0),
         %Profile{} = profile <- module.profile() do
      profile
    else
      _ ->
        Mix.raise(
          "--profile must be \"default\", \"bonfire\", or a loaded module exposing " <>
            "profile/0 returning a %SurfaceEject.Profile{} — got: #{module_name}"
        )
    end
  end
end
