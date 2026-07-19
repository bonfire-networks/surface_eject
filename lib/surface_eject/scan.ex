defmodule SurfaceEject.Scan do
  @moduledoc """
  The read-only scan phase: extracts each module's Surface component type
  (directly-`use`d or via profile-declared web-macro atoms) and its aliases,
  so the convert phase can resolve component call sites project-wide.
  """

  alias SurfaceEject.Context

  @direct_uses %{
    [:Surface, :Component] => :function_component,
    [:Surface, :LiveComponent] => :live_component,
    [:Surface, :LiveView] => :live_view
  }

  @doc """
  Scans one `.ex` source. Returns `%{module: String.t() | nil, type: atom | nil,
  aliases: %{"Short" => "Full.Module"}}`.
  """
  def scan_source(source, %Context{} = ctx) do
    ast = Sourceror.parse_string!(source)
    web_macros = web_macros(ctx)

    {_, acc} =
      Macro.prewalk(ast, %{module: nil, type: nil, aliases: %{}}, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, %{acc | module: acc.module || Enum.join(parts, ".")}}

        {:use, _, [{:__aliases__, _, parts} | rest]} = node, acc ->
          {node, %{acc | type: acc.type || use_type(parts, rest, web_macros)}}

        {:alias, _, _} = node, acc ->
          {node, %{acc | aliases: Map.merge(acc.aliases, alias_entries(node))}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  @doc "Merges scan results into a `%{\"Full.Module\" => type}` map (nil types dropped)."
  def build(scans) do
    for %{module: mod, type: type} <- scans, mod != nil, type != nil, into: %{} do
      {mod, type}
    end
  end

  defp web_macros(%{profile: %{web_macros: map}}) when is_map(map), do: map
  defp web_macros(_), do: %{}

  defp use_type(parts, _rest, _web_macros) when is_map_key(@direct_uses, parts),
    do: @direct_uses[parts]

  defp use_type(_parts, rest, web_macros) do
    case rest do
      [atom | _] when is_atom(atom) -> web_macros[atom]
      [{:__block__, _, [atom]} | _] when is_atom(atom) -> web_macros[atom]
      _ -> nil
    end
  end

  defp alias_entries({:alias, _, [{:__aliases__, _, parts}]}) do
    %{"#{List.last(parts)}" => Enum.join(parts, ".")}
  end

  defp alias_entries({:alias, _, [{:__aliases__, _, parts}, opts]}) do
    full = Enum.join(parts, ".")

    case as_option(opts) do
      nil -> %{"#{List.last(parts)}" => full}
      short -> %{short => full}
    end
  end

  defp alias_entries({:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, children}]}) do
    base = Enum.join(prefix, ".")

    for {:__aliases__, _, parts} <- children, into: %{} do
      {"#{List.last(parts)}", base <> "." <> Enum.join(parts, ".")}
    end
  end

  defp alias_entries(_), do: %{}

  defp as_option(opts) when is_list(opts) do
    Enum.find_value(opts, fn
      {{:__block__, _, [:as]}, {:__aliases__, _, parts}} -> "#{List.last(parts)}"
      {:as, {:__aliases__, _, parts}} -> "#{List.last(parts)}"
      _ -> nil
    end)
  end

  defp as_option(_), do: nil
end
