defmodule Mix.Tasks.Surface.Eject do
  @shortdoc "Migrate Surface components/templates to plain Phoenix LiveView/HEEx"

  @moduledoc """
  #{@shortdoc}.

      mix surface.eject [--profile bonfire] [--path lib] [--dry-run]

  Igniter-powered: composes all changes and shows a diff before applying
  (`--dry-run` to only show it). Scans `.ex` files under `--path` for
  component types and aliases, converts `.ex` (declarations per profile +
  `~F` sigils) and `.sface` templates (renamed to `.heex`).

  Profiles: `default` (generic) or `bonfire`. See `SurfaceEject.Profile`.
  """

  use Igniter.Mix.Task

  alias SurfaceEject.{Profile, Runner}

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :surface_eject,
      example: "mix surface.eject --profile bonfire --path lib --dry-run",
      schema: [profile: :string, path: :string],
      defaults: [profile: "default", path: "lib"]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    profile = profile!(opts[:profile])
    path = opts[:path] || "lib"

    # read through Igniter's virtual FS (works with Igniter.Test projects too)
    igniter = Igniter.include_glob(igniter, Path.join(path, "**/*.{ex,sface}"))

    files =
      for source <- Rewrite.sources(igniter.rewrite),
          file = Rewrite.Source.get(source, :path),
          Path.extname(file) in [".ex", ".sface"],
          String.starts_with?(file, path),
          into: %{} do
        {file, Rewrite.Source.get(source, :content)}
      end

    {actions, _logs} = Runner.plan(files, profile)

    Enum.reduce(actions, igniter, fn
      {file, {:write, content, _logs}}, igniter ->
        update(igniter, file, content)

      {file, {:move, new_path, content, _logs}}, igniter ->
        igniter
        |> update(file, content)
        |> Igniter.move_file(file, new_path)

      {_file, :unchanged}, igniter ->
        igniter
    end)
  end

  defp update(igniter, path, content) do
    Igniter.update_file(igniter, path, fn source ->
      Rewrite.Source.update(source, :content, fn _ -> content end)
    end)
  end

  defp profile!("bonfire"), do: Profile.bonfire()
  defp profile!(_), do: %Profile{}
end
