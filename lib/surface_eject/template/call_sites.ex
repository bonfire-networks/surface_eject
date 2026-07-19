defmodule SurfaceEject.Template.CallSites do
  @moduledoc """
  Component call-site resolution and rewriting (M3):

    * function components (per type map, alias-aware) → `.render` suffix on
      open AND close tags (the `remote_call: :render` convention — converted
      modules keep their `render/1`)
    * live components → `<.live_component module={Full.Module} ...>` — unless
      the call passes SLOT ENTRIES (`<:name>`), which `<.live_component>`
      cannot receive: flagged `:manual_required`, left unchanged
    * project dynamic-dispatch wrappers (profile `dynamic_dispatch`) →
      `.render` suffix
    * Surface built-ins (resolved to `Surface.Components.*`) → flagged
      `:manual_required`, left unchanged (small counts; profile form-mapping
      is post-MVP)
    * anything else PascalCase → `:unknown_component` info log
  """

  @doc """
  Pre-pairs component tags: returns `%{open_pos => %{slot_children: bool},
  close_pos => {:close_of, open_pos}}` keyed by tag meta `{line, column}`.
  """
  def prescan(tokens) do
    {pairs, _stack} =
      Enum.reduce(tokens, {%{}, []}, fn
        {:tag_open, ":" <> _name, _attrs, _meta}, {pairs, [{_, top_pos} | _] = stack} ->
          {Map.update!(pairs, top_pos, &%{&1 | slot_children: true}), stack}

        {:tag_open, _name, _attrs, %{self_close: true}}, acc ->
          acc

        {:tag_open, _name, _attrs, %{void_tag?: true}}, acc ->
          acc

        {:tag_open, name, _attrs, meta}, {pairs, stack} ->
          pos = {meta.line, meta.column}
          {Map.put(pairs, pos, %{slot_children: false}), [{name, pos} | stack]}

        {:tag_close, name, meta}, {pairs, [{name, open_pos} | rest]} ->
          {Map.put(pairs, {meta.line, meta.column}, {:close_of, open_pos}), rest}

        _token, acc ->
          acc
      end)

    pairs
  end

  @doc """
  Resolves a tag name to a rewrite action:
  `:skip | :render_suffix | {:live_component, full} | :surface_builtin | :unknown_component`.
  """
  def resolve(name, ctx) do
    cond do
      not String.match?(name, ~r/^[A-Z]/) ->
        :skip

      dynamic_dispatch(ctx)[name] == :suffix_render ->
        :render_suffix

      true ->
        resolved = resolve_alias(name, aliases(ctx))

        cond do
          String.starts_with?(resolved, "Surface.Components.") -> :surface_builtin
          type(ctx, resolved) == :function_component -> :render_suffix
          type(ctx, resolved) == :live_component -> {:live_component, resolved}
          true -> :unknown_component
        end
    end
  end

  @doc "Expands the leading segment of `name` through the alias map."
  def resolve_alias(name, aliases) do
    case String.split(name, ".", parts: 2) do
      [first] -> aliases[first] || name
      [first, rest] -> if full = aliases[first], do: full <> "." <> rest, else: name
    end
  end

  defp type(ctx, resolved), do: ctx.type_map[resolved]
  defp aliases(%{aliases: a, profile: %{aliases: pa}}) when is_map(pa), do: Map.merge(pa, a)
  defp aliases(%{aliases: a}), do: a

  defp dynamic_dispatch(%{profile: %{dynamic_dispatch: d}}) when is_map(d), do: d
  defp dynamic_dispatch(_), do: %{}
end
