defmodule SurfaceEject.Files do
  @moduledoc """
  File-selection policy shared by both frontends: which paths a glob result
  may include. Exclusion entries match any path SEGMENT, so `"deps"` skips
  `deps/foo/bar.ex` at any depth.
  """

  @default_excludes ~w(deps _build node_modules)

  def default_excludes, do: @default_excludes

  def excluded?(path, excludes) do
    segments = Path.split(path)
    Enum.any?(excludes, &(&1 in segments))
  end

  @doc """
  Lists convertible files under `root` with exclusions PRUNED DURING traversal, a glob that lists first and filters after can spend minutes walking `node_modules`/`deps` trees. Dot-directories and symlinked directories are skipped (symlinks can cycle).
  """
  def list_files(root, extra_excludes) do
    excludes = @default_excludes ++ extra_excludes
    walk(root, excludes, [])
  end

  defp walk(dir, excludes, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, acc ->
          full = Path.join(dir, entry)

          cond do
            String.starts_with?(entry, ".") or entry in excludes -> acc
            dir?(full) -> walk(full, excludes, acc)
            Path.extname(entry) in [".ex", ".sface"] -> [full | acc]
            true -> acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  # lstat: a symlinked directory reports :symlink, not :directory — skipped
  defp dir?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  @doc """
  The full selection policy, shared by both frontends: from candidate paths,
  keep convertible extensions minus exclusions, split into
  `{convert_paths, scan_only_paths}` by root. Frontends only supply the
  listing (glob vs virtual FS) and the reading.
  """
  def partition(paths, convert_root, scan_roots, extra_excludes) do
    excludes = @default_excludes ++ extra_excludes

    # a convert root nested inside a scan root lists its files twice
    eligible =
      paths
      |> Enum.uniq()
      |> Enum.filter(fn path ->
        Path.extname(path) in [".ex", ".sface"] and not excluded?(path, excludes)
      end)

    {
      Enum.filter(eligible, &String.starts_with?(&1, convert_root)),
      Enum.filter(eligible, fn path ->
        Enum.any?(scan_roots, &String.starts_with?(path, &1))
      end)
    }
  end
end
