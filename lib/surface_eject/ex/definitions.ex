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
    {source, rename_logs} = rewrite_calls(source, ctx)
    atom_logs = direct_logs ++ atom_logs ++ rename_logs

    case declarations_mode(ctx) do
      :compat ->
        {source, atom_logs}

      :native ->
        {source, logs} = native_convert(source, ctx)
        {source, atom_logs ++ logs}

      _attr ->
        {source, logs} = do_convert(source, ctx)
        {source, atom_logs ++ logs}
    end
  end

  ## :native — the most native construct available per module kind:
  ## function components get real attr/slot (emitting the delegating render
  ## for embedded-template modules so attrs have a def to bind to); stateful
  ## declarations become surf_live_attr's `live_attr` (active, or COMMENTED
  ## when the project doesn't use the lib — the file must still compile)

  @surface_only_opts [:from_context, :static, :accumulate, :css_variant]

  defp native_convert(source, ctx) do
    ast = Sourceror.parse_string!(source)
    groups = collect_groups(ast)
    kind = ctx.type_map[ctx.module]

    # attrs bind the NEXT def — safe only for truly adjacent groups, or when
    # the delegating render will be emitted right after the declarations
    will_delegate =
      kind == :function_component and embedded_render_delegate(ctx) != nil and
        not has_render_def?(ast)

    {patches, logs} =
      Enum.reduce(groups, {[], []}, fn {decls, adjacent?}, acc ->
        Enum.reduce(decls, acc, fn {decl, doc}, {patches, logs} ->
          native_patch({kind, adjacent? or will_delegate}, decl, doc, ctx, patches, logs)
        end)
      end)

    {patches, logs} = maybe_emit_delegate(kind, ast, groups, ctx, patches, logs)

    {Sourceror.patch_string(source, patches), Enum.reverse(logs)}
  end

  # function components: prop/slot native attr where binding is safe;
  # otherwise live_attr (position-independent defaults, no binding target
  # needed — e.g. macro calls between the declarations and render/1)
  defp native_patch({:function_component, _}, {:data, _, _} = decl, doc, ctx, patches, logs) do
    live_attr_patch(decl, doc, false, ctx, patches, logs)
  end

  defp native_patch({:function_component, true}, decl, doc, ctx, patches, logs) do
    decl_patch(decl, doc, true, ctx, patches, logs)
  end

  defp native_patch({:function_component, false}, {:slot, _, _} = decl, doc, ctx, patches, logs) do
    delete_decl(
      decl,
      doc,
      "slot declaration not adjacent to render/1 — removed (slot assigns arrive regardless)",
      ctx,
      patches,
      logs
    )
  end

  defp native_patch({:function_component, false}, {:prop, _, _} = decl, doc, ctx, patches, logs) do
    live_attr_patch(decl, doc, false, ctx, patches, logs)
  end

  defp native_patch({:live_component, _}, {:slot, _, _} = decl, doc, ctx, patches, logs) do
    delete_decl(decl, doc, "slot declaration removed (slot assigns arrive regardless)", ctx, patches, logs)
  end

  defp native_patch({:live_component, _}, {:data, _, _} = decl, doc, ctx, patches, logs) do
    live_attr_patch(decl, doc, true, ctx, patches, logs)
  end

  defp native_patch({:live_component, _}, {:prop, _, _} = decl, doc, ctx, patches, logs) do
    live_attr_patch(decl, doc, false, ctx, patches, logs)
  end

  defp native_patch({:live_view, _}, {:data, _, _} = decl, doc, ctx, patches, logs) do
    live_attr_patch(decl, doc, false, ctx, patches, logs)
  end

  defp native_patch({:live_view, _}, {kind, _, _} = decl, doc, ctx, patches, logs)
       when kind in [:prop, :slot] do
    delete_decl(decl, doc, "#{kind} declaration is inert on a LiveView — removed", ctx, patches, logs)
  end

  # unknown module kind: conservative :attr behavior
  defp native_patch({_kind, adjacent?}, decl, doc, ctx, patches, logs) do
    decl_patch(decl, doc, adjacent?, ctx, patches, logs)
  end

  # `prop name, :type, opts` / `data ...` → `live_attr :name, :type, opts`
  # (original type kept — live_attr records it as metadata)
  defp live_attr_patch({_kind, _, [{name, _, var_ctx}, type | rest]} = decl, doc, internal?, ctx, patches, logs)
       when is_atom(name) and is_atom(var_ctx) do
    line = Sourceror.get_line(decl)
    {rest, _dropped} = drop_opt_keys(rest, @surface_only_opts)

    internal = if internal?, do: ", internal: true", else: ""
    text = "live_attr :#{name}, #{inspect(unwrap_atom(type))}#{opts_suffix(rest)}#{internal}#{doc_suffix(doc)}"

    if live_attr?(ctx) do
      {[%{range: decl_range(decl, doc), change: text} | patches], logs}
    else
      patches = [%{range: decl_range(decl, doc), change: "# " <> text} | patches]

      {patches,
       [
         log(
           ctx,
           :manual_required,
           :live_attr_commented,
           line,
           "translated to `#{text}` but COMMENTED — add {:surf_live_attr, ...} and uncomment (defaults are not applied until then)"
         )
         | logs
       ]}
    end
  end

  # declarations without a var-form name (already-plain etc.): leave
  defp live_attr_patch(_decl, _doc, _internal?, _ctx, patches, logs), do: {patches, logs}

  defp delete_decl(decl, doc, message, ctx, patches, logs) do
    {[%{range: decl_range(decl, doc), change: ""} | patches],
     [log(ctx, :info, :decl_removed, Sourceror.get_line(decl), message) | logs]}
  end

  # emit `def render(assigns), do: <delegate>(assigns)` after the last
  # declaration when the module has no 1-arity def of its own (embedded
  # templates: the def gives attrs something to bind before web.ex's embed)
  defp maybe_emit_delegate(:function_component, ast, groups, ctx, patches, logs) do
    delegate = embedded_render_delegate(ctx)
    decls = Enum.flat_map(groups, fn {decls, _adj} -> Enum.map(decls, &elem(&1, 0)) end)

    if delegate && decls != [] && not has_render_def?(ast) do
      last = Enum.max_by(decls, &(Sourceror.get_range(&1).end[:line]))
      pos = Sourceror.get_range(last).end

      insertion = %{
        range: %{start: pos, end: pos},
        change: "\n\n  def render(assigns), do: #{delegate}(assigns)"
      }

      {[insertion | patches],
       [
         log(
           ctx,
           :info,
           :render_delegate,
           pos[:line],
           "emitted `def render(assigns), do: #{delegate}(assigns)` so the converted attrs bind to it"
         )
         | logs
       ]}
    else
      {patches, logs}
    end
  end

  defp maybe_emit_delegate(_kind, _ast, _groups, _ctx, patches, logs), do: {patches, logs}

  # specifically render/1 — any other def (helpers of any arity) neither
  # satisfies the attrs' binding target nor should suppress the delegate
  defp has_render_def?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn node, acc ->
        {node, acc or render_def?(node)}
      end)

    found
  end

  defp render_def?({def_kind, _, [head | _]}) when def_kind in [:def, :defp],
    do: render_head?(head)

  defp render_def?(_), do: false

  defp render_head?({:when, _, [head | _]}), do: render_head?(head)
  defp render_head?({:render, _, [_arg]}), do: true
  defp render_head?(_), do: false

  defp live_attr?(%{profile: %{live_attr: flag}}), do: flag == true
  defp live_attr?(_), do: false

  defp embedded_render_delegate(%{profile: %{embedded_render_delegate: delegate}}), do: delegate
  defp embedded_render_delegate(_), do: nil

  defp drop_opt_keys([], _keys), do: {[], false}

  defp drop_opt_keys([opts], keys) do
    case drop_keys(opts, keys) do
      {same, false} -> {[same], false}
      {[], true} -> {[], true}
      {remaining, true} -> {[remaining], true}
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
    if web_macro_module?(source, ctx) do
      # The web-macro HOME (defines the `use MyWeb, :atom` shorthands from the
      # profile's web_macros/use_atom_map — e.g. Bonfire's web.ex) is NOT a
      # component: it must keep BOTH `use Surface.Component` (in its
      # `stateless_component` macro) and `use Phoenix.Component` (in
      # `function_component`) so still-Surface callers in OTHER extensions keep
      # compiling mid-migration. So don't swap its `use Surface.*` — everything
      # else still patches.
      {source, []}
    else
      do_rewrite_direct_surface_uses(source, ctx)
    end
  end

  # The module that DEFINES the web-macro shorthands has a `def <atom>(` (or
  # `defmacro`) for atoms named in the profile's `use_atom_map` (keys AND values)
  # or `web_macros` — i.e. it defines `stateless_component`/`function_component`/…
  # rather than USING them.
  defp web_macro_module?(source, %{profile: %{} = profile}) do
    atoms =
      Map.keys(Map.get(profile, :use_atom_map) || %{}) ++
        Map.values(Map.get(profile, :use_atom_map) || %{}) ++
        Map.keys(Map.get(profile, :web_macros) || %{})

    atoms != [] and
      Enum.any?(atoms, fn atom ->
        source =~ ~r/\bdef(macro)?\s+#{Regex.escape(to_string(atom))}\(/
      end)
  end

  defp web_macro_module?(_source, _ctx), do: false

  defp do_rewrite_direct_surface_uses(source, ctx) do
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

  # profile call_renames: local helper calls → their plain-stack analogues
  # (e.g. Bonfire's render_sface() → render_template())
  defp rewrite_calls(source, ctx) do
    renames = call_renames(ctx)

    if renames == %{} do
      {source, []}
    else
      ast = Sourceror.parse_string!(source)

      {_, {patches, logs}} =
        Macro.prewalk(ast, {[], []}, fn
          {name, meta, args} = node, {patches, logs}
          when is_atom(name) and is_list(args) and is_map_key(renames, name) ->
            new_name = to_string(renames[name])
            start = [line: meta[:line], column: meta[:column]]
            fin = [line: meta[:line], column: meta[:column] + String.length(to_string(name))]
            patch = %{range: %{start: start, end: fin}, change: new_name}

            {node,
             {[patch | patches],
              [
                log(ctx, :info, :call_rename, meta[:line], "#{name}() → #{new_name}()")
                | logs
              ]}}

          node, acc ->
            {node, acc}
        end)

      {Sourceror.patch_string(source, patches), Enum.reverse(logs)}
    end
  end

  defp call_renames(%{profile: %{call_renames: map}}) when is_map(map), do: map
  defp call_renames(_), do: %{}

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

  # only Surface's bare-identifier form (`prop label, ...`, `slot default`) is
  # a declaration — Phoenix's own `attr :x`/`slot :x` take a literal atom, and
  # matching those would re-convert already-plain modules (idempotency)
  defp decl?({name, _, [{arg, _, var_ctx} | _]})
       when name in [:prop, :slot, :data] and is_atom(arg) and is_atom(var_ctx),
       do: true

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

  # only genuine Surface var-form declarations flag; already-plain
  # literal-atom forms (re-runs) fall through untouched
  defp decl_patch({_, _, [{name, _, var_ctx} | _]} = decl, _doc, false, ctx, patches, logs)
       when is_atom(name) and is_atom(var_ctx) do
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

    # Phoenix VALIDATES attr defaults against the type; Surface never did,
    # so lying declarations exist — fall back to :any rather than emit a
    # compile error
    {mapped, logs} =
      if default_conflicts?(rest, mapped) do
        {:any,
         [
           log(
             ctx,
             :warning,
             :attr_type_conflict,
             line,
             "prop #{name}: default value conflicts with declared type #{inspect(mapped)} — emitted :any (Phoenix validates, Surface didn't)"
           )
           | logs
         ]}
      else
        {mapped, logs}
      end

    text = "attr :#{name}, #{inspect(mapped)}#{opts_suffix(rest)}#{doc_suffix(doc)}"
    patches = [%{range: decl_range(decl, doc), change: text} | patches]

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
    patches = [%{range: decl_range(decl, doc), change: text} | patches]

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
      string -> ", doc: #{inspect(String.trim(string))}"
    end
  end

  # one patch spanning @doc through the declaration — separate deletion
  # patches leave blank lines and interact badly with heredoc ranges
  defp decl_range(decl, doc) do
    if doc_string(doc),
      do: %{start: Sourceror.get_range(doc).start, end: Sourceror.get_range(decl).end},
      else: Sourceror.get_range(decl)
  end

  # does the literal default clash with the (mapped) attr type?
  defp default_conflicts?(rest_opts, mapped_type) when mapped_type != :any do
    case find_opt_value(rest_opts, :default) do
      nil -> false
      value_ast -> literal_conflicts?(literal_of(value_ast), mapped_type)
    end
  end

  defp default_conflicts?(_rest, _any), do: false

  defp find_opt_value([opts], key) do
    entries =
      case opts do
        {:__block__, _, [list]} when is_list(list) -> list
        list when is_list(list) -> list
        _ -> []
      end

    Enum.find_value(entries, fn
      {{:__block__, _, [^key]}, value} -> value
      {^key, value} -> value
      _ -> nil
    end)
  end

  defp find_opt_value(_, _key), do: nil

  defp literal_of({:__block__, _, [literal]}), do: literal_of(literal)
  defp literal_of(literal), do: literal

  # nil defaults are valid for every attr type; non-literal exprs can't be
  # checked statically — both report no conflict
  defp literal_conflicts?(nil, _type), do: false

  defp literal_conflicts?(value, type) do
    case type do
      :string -> known_literal?(value) and not is_binary(value)
      :boolean -> known_literal?(value) and not is_boolean(value)
      :integer -> known_literal?(value) and not is_integer(value)
      :float -> known_literal?(value) and not is_number(value)
      :atom -> known_literal?(value) and not is_atom(value)
      :list -> known_literal?(value) and not is_list(value)
      :map -> known_literal?(value) and not map_literal?(value)
      _ -> false
    end
  end

  defp known_literal?(value),
    do:
      is_binary(value) or is_atom(value) or is_number(value) or is_list(value) or
        map_literal?(value)

  defp map_literal?(value),
    do: is_map(value) or match?({:%{}, _, _}, value) or match?({:%, _, _}, value)

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
    # explicit locals_without_parens: Sourceror otherwise lazily asks
    # Mix.Tasks.Format for it, and Mix does not exist inside the escript
    rendered = Sourceror.to_string(opts_ast, locals_without_parens: [])

    if String.starts_with?(rendered, "["),
      do: rendered |> String.slice(1..-2//1) |> String.trim(),
      else: rendered
  end

  defp drop_slot_args([]), do: {[], false}

  defp drop_slot_args([opts]) do
    case drop_keys(opts, [:arg, :args]) do
      {same, false} -> {[same], false}
      {[], true} -> {[], true}
      {remaining, true} -> {[remaining], true}
    end
  end

  # opts are a keyword-list AST: a list of {key_ast, value_ast} pairs
  defp drop_keys({:__block__, meta, [list]}, keys) when is_list(list) do
    {kept, dropped} = drop_keys(list, keys)
    {{:__block__, meta, [kept]}, dropped}
  end

  defp drop_keys(list, keys) when is_list(list) do
    {kept, dropped} =
      Enum.reduce(list, {[], false}, fn
        {{:__block__, _, [key]}, _v} = pair, {acc, dropped} ->
          if key in keys, do: {acc, true}, else: {[pair | acc], dropped}

        {key, _v} = pair, {acc, dropped} when is_atom(key) ->
          if key in keys, do: {acc, true}, else: {[pair | acc], dropped}

        pair, {acc, dropped} ->
          {[pair | acc], dropped}
      end)

    {Enum.reverse(kept), dropped}
  end

  defp drop_keys(other, _keys), do: {other, false}

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
