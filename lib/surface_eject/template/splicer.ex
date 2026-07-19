defmodule SurfaceEject.Template.Splicer do
  @moduledoc """
  Position-driven source splicing: applies a list of replacement regions
  (char ranges derived from Surface tokenizer metadata) to the original
  source, copying everything outside the regions byte-for-byte.

  This is the same principle as Surface's own `Surface.Compiler.Converter`
  driver (its 0.x→0.y converter), reimplemented leaner: instead of a
  char-by-char scan with a callback behaviour, the transform pass produces
  explicit `{start, end, replacement}` regions up front and this module
  splices them. Zero-width regions (`start == end`) are insertions.

  Positions are `{line, column}` (1-based, as emitted by
  `Surface.Compiler.Tokenizer`); columns are counted in characters.
  """

  @doc """
  Applies `regions` — a list of `{{start_line, start_col}, {end_line, end_col}, replacement}`
  with EXCLUSIVE end positions — to `source`. Regions must not overlap.
  """
  def splice(source, regions) do
    index = line_offsets(source)

    regions
    |> Enum.map(fn {start_pos, end_pos, text} ->
      {pos_to_offset(index, start_pos), pos_to_offset(index, end_pos), text}
    end)
    |> Enum.sort()
    |> validate_no_overlap!()
    |> apply_regions(source)
  end

  @doc "Converts a `{line, column}` position to a character offset in `source`'s index."
  def pos_to_offset(index, {line, col}), do: elem(index, line - 1) + (col - 1)

  @doc "Builds a tuple of cumulative character offsets per line (newline included)."
  def line_offsets(source) do
    source
    |> String.split("\n")
    |> Enum.reduce({0, []}, fn line, {off, acc} ->
      {off + String.length(line) + 1, [off | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp validate_no_overlap!(sorted) do
    sorted
    |> Enum.reduce(-1, fn {start, stop, _}, prev_end ->
      if start < prev_end do
        raise ArgumentError,
              "overlapping splice regions at offset #{start} (previous ends #{prev_end})"
      end

      max(stop, prev_end)
    end)

    sorted
  end

  defp apply_regions(sorted, source) do
    {iodata, cursor} =
      Enum.reduce(sorted, {[], 0}, fn {start, stop, text}, {acc, cursor} ->
        {[acc, String.slice(source, cursor, start - cursor), text], stop}
      end)

    IO.iodata_to_binary([iodata, String.slice(source, cursor, String.length(source) - cursor)])
  end
end
