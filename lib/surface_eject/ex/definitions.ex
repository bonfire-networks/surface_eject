defmodule SurfaceEject.Ex.Definitions do
  @moduledoc """
  Converts Surface declarations in `.ex` module bodies via Sourceror
  range-patches (formatting outside the patched calls is preserved):

    * `prop name, :type, opts` → `attr :name, :mapped_type, opts`
      (generic `:attr` mode only, and only for declaration groups ADJACENT to
      a following 1-arity def — dangling `attr` lines are compile errors)
    * `slot default, opts` → `slot :inner_block, opts`; `slot name` →
      `slot :name`; `arg:`/`args:` options dropped (their semantics live in
      the caller's `:let`) — never emit HEEx slot-attr blocks
    * `data` — left untouched and flagged (generation of `update/2` merges is
      post-MVP; `:compat` projects keep Surface-shaped decls via their macro
      layer)

  In `:compat` mode this whole pass is a no-op.
  """

  alias SurfaceEject.{Context, LogEntry}
  alias SurfaceEject.Ex.TypeTable

  @doc "Returns `{converted_source, logs}`."
  def convert(source, %Context{} = ctx) do
    {source, direct_logs} = rewrite_direct_surface_uses(source, ctx)
    {source, atom_logs} = rewrite_use_atoms(source, ctx)
    atom_logs = direct_logs ++ atom_logs

    if declarations_mode(ctx) == :compat do
      {source, atom_logs}
    else
      {source, logs} = do_convert(source, ctx)
      {source, atom_logs ++ logs}
    end
  end

  # `use Surface.Component` → `use Phoenix.Component` etc. — converted
  # declarations/templates cannot compile through Surface's macros
  @direct_use_map %{
    [:Surface, :Component] => "Phoenix.Component",
    [:Surface, :LiveComponent] => "Phoenix.LiveComponent",
    [:Surface, :LiveView] => "Phoenix.LiveView"
  }

  defp rewrite_direct_surface_uses(source, ctx) do
    ast = Sourceror.parse_string!(source)

    {_, {patches, logs}} =
      Macro.prewalk(ast, {[], []}, fn
        {:use, _, [{:__aliases__, _, segments} = alias_node | _]} = node, {patches, logs}
        when is_map_key(@direct_use_map, segments) ->
          replacement = @direct_use_map[segments]
          patch = %{range: Sourceror.get_range(alias_node), change: replacement}

          {node,
           {[patch | patches],
            [
              log(
                ctx,
                :info,
                :use_module,
                Sourceror.get_line(node),
                "use #{Enum.join(segments, ".")} → use #{replacement}"
              )
              | logs
            ]}}

        node, acc ->
          {node, acc}
      end)

    {Sourceror.patch_string(source, patches), Enum.reverse(logs)}
  end

  # `use MyWeb, :surface_atom` → `use MyWeb, :plain_atom` (profile use_atom_map)
  # — converted modules must compile through the context-lib-wired plain macros
  defp rewrite_use_atoms(source, ctx) do
    atom_map = use_atom_map(ctx)

    if atom_map == %{} do
      {source, []}
    else
      ast = Sourceror.parse_string!(source)

      use_like = use_like_macros(ctx)

      {_, {patches, logs}} =
        Macro.prewalk(ast, {[], []}, fn
          {macro, _, [{:__aliases__, _, _} | rest]} = node, {patches, logs} = acc
          when is_atom(macro) ->
            with true <- macro == :use or macro in use_like,
                 {atom_node, atom} when is_map_key(atom_map, atom) <- use_atom(rest) do
              patch = %{range: Sourceror.get_range(atom_node), change: inspect(atom_map[atom])}

              {node,
               {[patch | patches],
                [
                  log(
                    ctx,
                    :info,
                    :use_atom,
                    Sourceror.get_line(node),
                    "#{macro} atom #{inspect(atom)} → #{inspect(atom_map[atom])} (plain context-lib-wired macro)"
                  )
                  | logs
                ]}}
            else
              _ -> {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      {Sourceror.patch_string(source, patches), Enum.reverse(logs)}
    end
  end

  defp use_atom([{:__block__, _, [atom]} = node | _]) when is_atom(atom), do: {node, atom}
  defp use_atom([atom | _]) when is_atom(atom), do: {atom, atom}
  defp use_atom(_), do: nil

  defp use_atom_map(%{profile: %{use_atom_map: map}}) when is_map(map), do: map
  defp use_atom_map(_), do: %{}

  defp use_like_macros(%{profile: %{use_like_macros: list}}) when is_list(list), do: list
  defp use_like_macros(_), do: []

  defp declarations_mode(%{profile: %{declarations: mode}}), do: mode
  defp declarations_mode(_), do: :attr

  defp do_convert(source, ctx) do
    ast = Sourceror.parse_string!(source)
    groups = collect_groups(ast)

    {patches, logs} =
      Enum.reduce(groups, {[], []}, fn {decls, adjacent?}, acc ->
        Enum.reduce(decls, acc, fn {decl, doc}, {patches, logs} ->
          decl_patch(decl, doc, adjacent?, ctx, patches, logs)
        end)
      end)

    {Sourceror.patch_string(source, patches), Enum.reverse(logs)}
  end

  ## group collection: contiguous prop/slot/data runs in module bodies,
  ## tagged with whether a 1-arity def follows

  defp collect_groups(ast) do
    {_, groups} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [_name, [{{:__block__, _, [:do]}, body} | _]]} = node, acc ->
          {node, acc ++ body_groups(body)}

        {:defmodule, _, [_name, [do: body]]} = node, acc ->
          {node, acc ++ body_groups(body)}

        node, acc ->
          {node, acc}
      end)

    groups
  end

  defp body_groups({:__block__, _, stmts}), do: scan(stmts, nil, [], [])
  defp body_groups(single), do: scan([single], nil, [], [])

  defp scan([], _pending_doc, current, groups),
    do: flush(current, false, groups) |> Enum.reverse()

  defp scan([stmt | rest], pending_doc, current, groups) do
    cond do
      decl?(stmt) ->
        # a preceding `@doc` pairs with THIS declaration (Surface consumed it; Phoenix attr/slot won't — it gets folded into a doc: option)
        scan(rest, nil, [{stmt, pending_doc} | current], groups)

      doc_attr?(stmt) ->
        scan(rest, stmt, current, groups)

      # other module attributes between declarations don't break a group
      match?({:@, _, _}, stmt) and current != [] ->
        scan(rest, pending_doc, current, groups)

      component_def?(stmt) ->
        # pending @doc before a def belongs to the def — leave it alone
        scan(rest, nil, [], flush(current, true, groups))

      true ->
        scan(rest, nil, [], flush(current, false, groups))
    end
  end

  defp doc_attr?({:@, _, [{:doc, _, [_]}]}), do: true
  defp doc_attr?(_), do: false

  defp flush([], _adjacent?, groups), do: groups
  defp flush(current, adjacent?, groups), do: [{Enum.reverse(current), adjacent?} | groups]

  defp decl?({name, _, args}) when name in [:prop, :slot, :data] and is_list(args), do: true
  defp decl?(_), do: false

  defp component_def?({def_kind, _, [head | _]}) when def_kind in [:def, :defp] do
    arity_one?(head)
  end

  defp component_def?(_), do: false

  defp arity_one?({:when, _, [head | _]}), do: arity_one?(head)
  defp arity_one?({_name, _, [_arg]}), do: true
  defp arity_one?(_), do: false

  ## per-declaration patches

  defp decl_patch({:data, meta, _args} = _decl, _doc, _adjacent?, ctx, patches, logs) do
    {patches,
     [
       log(
         ctx,
         :warning,
         :data_decl,
         meta[:line],
         "data declaration left as-is (state semantics — convert manually or use compat macros)"
       )
       | logs
     ]}
  end

  defp decl_patch(decl, _doc, false, ctx, patches, logs) do
    {_, meta, _} = decl

    {patches,
     [
       log(
         ctx,
         :manual_required,
         :attr_adjacency,
         meta[:line],
         "declaration not adjacent to a 1-arity def — left unconverted (dangling attr lines would not compile)"
       )
       | logs
     ]}
  end

  defp decl_patch(
         {:prop, _meta, [{name, _, var_ctx}, type | rest]} = decl,
         doc,
         true,
         ctx,
         patches,
         logs
       )
       when is_atom(name) and is_atom(var_ctx) do
    {mapped, log_cat} = TypeTable.map(unwrap_atom(type))
    line = Sourceror.get_line(decl)

    text = "attr :#{name}, #{inspect(mapped)}#{opts_suffix(rest)}#{doc_suffix(doc)}"
    patches = doc_patches(doc, patches)
    patches = [%{range: Sourceror.get_range(decl), change: text} | patches]

    logs =
      if log_cat,
        do: [
          log(
            ctx,
            :warning,
            log_cat,
            line,
            "prop #{name} type #{inspect(unwrap_atom(type))} mapped to #{inspect(mapped)}"
          )
          | logs
        ],
        else: logs

    {patches, logs}
  end

  # only the VAR form (`slot default` — Surface syntax) converts; a literal
  # atom (`slot :inner_block`, already-plain Phoenix, wrapped by Sourceror as
  # `{:__block__, _, [atom]}`) must fall through untouched (re-run safety)
  defp decl_patch(
         {:slot, _meta, [{name, _, var_ctx} | rest]} = decl,
         doc,
         true,
         ctx,
         patches,
         logs
       )
       when is_atom(name) and is_atom(var_ctx) do
    line = Sourceror.get_line(decl)
    slot_name = if name == :default, do: :inner_block, else: name

    {rest, dropped_arg?} = drop_slot_args(rest)

    text = "slot #{inspect(slot_name)}#{opts_suffix(rest)}#{doc_suffix(doc)}"
    patches = doc_patches(doc, patches)
    patches = [%{range: Sourceror.get_range(decl), change: text} | patches]

    logs =
      if dropped_arg?,
        do: [
          log(
            ctx,
            :info,
            :slot_arg,
            line,
            "slot #{name} arg(s) dropped — semantics live in the caller's :let"
          )
          | logs
        ],
        else: logs

    {patches, logs}
  end

  defp decl_patch(_other, _doc, _adjacent?, _ctx, patches, logs), do: {patches, logs}

  ## helpers

  # a paired `@doc "..."` folds into the declaration's doc: option (Surface's macros consumed @doc; Phoenix's don't, left alone it would redefine repeatedly and end up documenting render/1); non-string @doc (false, dynamic) stays untouched
  defp doc_string({:@, _, [{:doc, _, [arg]}]}) do
    case arg do
      {:__block__, _, [string]} when is_binary(string) -> string
      string when is_binary(string) -> string
      _ -> nil
    end
  end

  defp doc_string(_), do: nil

  defp doc_suffix(doc) do
    case doc_string(doc) do
      nil -> ""
      string -> ", doc: #{inspect(string)}"
    end
  end

  defp doc_patches(doc, patches) do
    if doc_string(doc),
      do: [%{range: Sourceror.get_range(doc), change: ""} | patches],
      else: patches
  end

  defp unwrap_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp unwrap_atom(atom) when is_atom(atom), do: atom
  defp unwrap_atom(_), do: :any

  defp opts_suffix([]), do: ""

  defp opts_suffix([opts]) do
    case render_opts(opts) do
      "" -> ""
      rendered -> ", " <> rendered
    end
  end

  defp render_opts(opts_ast) do
    rendered = Sourceror.to_string(opts_ast)

    if String.starts_with?(rendered, "["),
      do: rendered |> String.slice(1..-2//1) |> String.trim(),
      else: rendered
  end

  defp drop_slot_args([]), do: {[], false}

  defp drop_slot_args([opts]) do
    case drop_keys(opts) do
      {same, false} -> {[same], false}
      {[], true} -> {[], true}
      {remaining, true} -> {[remaining], true}
    end
  end

  # opts are a keyword-list AST: a list of {key_ast, value_ast} pairs
  defp drop_keys({:__block__, meta, [list]}) when is_list(list) do
    {kept, dropped} = drop_keys(list)
    {{:__block__, meta, [kept]}, dropped}
  end

  defp drop_keys(list) when is_list(list) do
    {kept, dropped} =
      Enum.reduce(list, {[], false}, fn
        {{:__block__, _, [key]}, _v}, {acc, _} when key in [:arg, :args] -> {acc, true}
        {key, _v}, {acc, _} when key in [:arg, :args] -> {acc, true}
        pair, {acc, dropped} -> {[pair | acc], dropped}
      end)

    {Enum.reverse(kept), dropped}
  end

  defp drop_keys(other), do: {other, false}

  defp log(ctx, severity, category, line, message) do
    %LogEntry{
      phase: :ex,
      severity: severity,
      category: category,
      file: ctx.file,
      line: line,
      message: message
    }
  end
end
