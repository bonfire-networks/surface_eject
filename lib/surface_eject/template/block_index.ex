defmodule SurfaceEject.Template.BlockIndex do
  @moduledoc """
  A cheap pre-pass over the flat token list supplying the only two non-local
  facts the block transforms need:

    1. whether a `{#for}` block has an `{#else}` sub-block (needed
       retroactively at the open marker, for the `Enum.empty?` wrap), and
    2. which parent block (`if`/`unless` vs `for`) each `{#else}` belongs to.

  Keyed by the block-open token's `{line, column}` (of the name token).
  """

  @openers ~w(if unless case for)
  @sub_blocks ~w(else elseif match)

  @doc """
  Returns `%{for_else: MapSet of {line,col} of for-opens that have an else,
  else_parent: %{{line,col} of else-name-token => "if" | "unless" | "for"}}`.
  """
  def build(tokens) do
    {for_else, else_parent, _stack} =
      Enum.reduce(tokens, {MapSet.new(), %{}, []}, fn
        {:block_open, name, _expr, meta}, {for_else, else_parent, stack} when name in @openers ->
          {for_else, else_parent, [{name, {meta.line, meta.column}} | stack]}

        {:block_open, "else", _expr, meta},
        {for_else, else_parent, [{parent, parent_pos} | _] = stack} ->
          for_else =
            if parent == "for", do: MapSet.put(for_else, parent_pos), else: for_else

          {for_else, Map.put(else_parent, {meta.line, meta.column}, parent), stack}

        {:block_open, sub, _expr, _meta}, acc when sub in @sub_blocks ->
          # elseif/match don't push; parent stays on top
          acc

        {:block_close, name, _meta}, {for_else, else_parent, [{name, _} | rest]}
        when name in @openers ->
          {for_else, else_parent, rest}

        _token, acc ->
          acc
      end)

    %{for_else: for_else, else_parent: else_parent}
  end
end
