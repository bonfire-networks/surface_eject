defmodule SurfaceEject.Template do
  @moduledoc """
  The template conversion pass: Surface template source in, HEEx source out,
  plus a list of `SurfaceEject.LogEntry` records.

  Single-pass, position-driven splicing over `Surface.Compiler.Tokenizer`
  tokens (see `SurfaceEject.Template.Splicer`) — every transform is a local
  marker rewrite; untouched source is preserved byte-for-byte. The only
  non-local facts (for-else, else-parent) come from
  `SurfaceEject.Template.BlockIndex`.

  In M1, component call sites (PascalCase tags) are left untouched and logged
  as `:unknown_component` — call-site conversion arrives with the scan phase
  (type map) in M3.
  """

  alias SurfaceEject.{Context, LogEntry}
  alias SurfaceEject.Template.FieldClusters
  alias SurfaceEject.Template.{BlockIndex, CallSites, Slots, Splicer}

  # directives that are valid HEEx as-is
  @passthrough_directives ~w(:if :for :let)

  @doc """
  Converts Surface template `source` to HEEx.

  Returns `{output, logs}`.
  """
  def convert(source, %Context{} = ctx \\ %Context{}) do
    # source PRE-pass (before tokenizing, so spans stay consistent):
    # Surface's slot_assigned?/1 → a plain slot-assign presence check
    source =
      Regex.replace(~r/slot_assigned\?\(:(\w+)\)/, source, fn _, name ->
        name = if name == "default", do: "inner_block", else: name
        "(@#{name} && @#{name} != [])"
      end)

    tokens = Surface.Compiler.Tokenizer.tokenize!(source, file: ctx.file)
    index = BlockIndex.build(tokens)

    state = %{
      ctx: ctx,
      source: source,
      offsets: Splicer.line_offsets(source),
      index: index,
      pairs: CallSites.prescan(tokens),
      stack: [],
      slot_stack: [],
      # enclosing <Field>-style entries: {:convertible, access, var} (Field→div with an explicit form binding) or :opaque (flagged, as inner controls rely on Surface's form context and must NOT be tag-converted)
      field_stack: [],
      # pre-pass for Field↔Form pairing + form bindings
      clusters: FieldClusters.prescan(tokens, ctx),
      # attr positions already rewritten by form-component mapping (exempt from the comma-list flag)
      handled_attrs: MapSet.new(),
      # open macro components that were flagged (their close tags must not be renamed)
      macro_bail_stack: [],
      # open positions of <Link> tags that converted (their close renames too)
      converted_links: MapSet.new(),
      regions: [],
      logs: []
    }

    state = Enum.reduce(tokens, state, &token/2)

    {Splicer.splice(source, Enum.reverse(state.regions)), Enum.reverse(state.logs)}
  end

  ## token walk

  defp token({:block_open, name, expr, meta}, state) do
    block_open(name, expr_text(expr), block_span(expr, meta, state), meta, state)
  end

  defp token({:block_close, name, meta}, state) do
    span = {{meta.line, meta.column - 2}, {meta.line_end, meta.column_end + 1}}
    block_close(name, span, state)
  end

  defp token({:comment, text, %{visibility: :private} = meta}, state) do
    inner = String.slice(text, 4, String.length(text) - 7)
    span = {{meta.line, meta.column}, {meta.new_line, meta.new_column}}
    region(state, span, "<%!--#{inner}--%>")
  end

  defp token({:comment, _text, _meta}, state), do: state

  defp token({:tag_open, "#slot", attrs, meta}, state) do
    ref = Slots.ref_from_attrs(attrs)
    span = {{meta.line, meta.column - 1}, node_end(meta)}

    if meta.self_close do
      region(state, span, Slots.self_close(ref))
    else
      state = region(state, span, Slots.open_with_fallback(ref))

      # HEEx creates an inner_block entry for EVERY non-self-closing caller
      # (even `<Comp></Comp>` or named-slots-only bodies), so a converted
      # default-slot fallback only fires for self-closing callers
      state =
        if ref == nil do
          log(
            state,
            :warning,
            :default_slot_fallback,
            meta.line,
            "default-slot fallback: under HEEx, callers with a non-self-closing tag " <>
              "(even whitespace-only or named-slots-only bodies) produce a non-empty " <>
              "@inner_block, so this fallback only renders for self-closing callers — " <>
              "review callers (Surface rendered the fallback whenever no default content was passed)"
          )
        else
          state
        end

      %{state | slot_stack: [:slot | state.slot_stack]}
    end
  end

  defp token({:tag_close, "#slot", meta}, state) do
    span = {{meta.line, meta.column - 2}, {meta.line_end, meta.column_end + 1}}
    state = region(state, span, Slots.close_tag())
    %{state | slot_stack: tl(state.slot_stack)}
  end

  # MacroComponents (`<#Tag>`) are Surface-only syntax — invalid HEEx.
  # Mapped ones (profile macro_components) convert; the rest are flagged.
  defp token({:tag_open, "#" <> mname, attrs, meta}, state) do
    macro_open(mname, attrs, meta, state)
  end

  defp token({:tag_close, "#" <> mname, meta}, state) do
    macro_close(mname, meta, state)
  end

  defp token({:tag_open, name, attrs, meta}, state) do
    state = call_site_open(name, attrs, meta, state)
    Enum.reduce(attrs, state, &attr(&1, {name, meta}, &2))
  end

  defp token({:tag_close, name, meta}, state) do
    call_site_close(name, meta, state)
  end

  defp token(_other, state), do: state

  ## component call sites (M3)

  defp call_site_open(name, attrs, meta, state) do
    case CallSites.resolve(name, state.ctx) do
      :skip ->
        state

      :render_suffix ->
        region(state, tag_name_span(meta), name <> ".render")

      # a project dynamic-dispatch wrapper mapped to a local function component
      # (e.g. <StatelessComponent …> → <.dynamic_component …>): rename the tag,
      # attrs (incl. the existing module={…}) carry over verbatim
      {:local_component, fun} ->
        region(state, tag_name_span(meta), ".#{fun}")

      # `<.live_component>` accepts named slot entries (delivered to the
      # component as assigns — verified at runtime on LV 1.2), so ALL callers
      # convert the same way regardless of slots. full = nil for dynamic
      # dispatch (module is already an attr); a known static module gets
      # module={Full} added.
      {:live_component, full} ->
        module_attr = if full, do: " module={#{full}}", else: ""
        state = region(state, tag_name_span(meta), ".live_component#{module_attr}")

        if slot_children?(state, meta) do
          log(
            state,
            :info,
            :live_component_slots,
            meta.line,
            "<#{name}> passes slot entries → <.live_component> (delivered to the component as assigns)"
          )
        else
          state
        end

      {:surface_builtin, resolved} ->
        builtin_open(resolved, name, attrs, meta, state)

      # Surface rendered LiveView tags via live_render — emit that directly
      {:live_view, full} ->
        if meta.self_close do
          opts =
            Enum.map_join(attrs, ", ", fn
              {aname, nil, _} -> "#{aname}: true"
              {aname, {:expr, expr, _}, _} -> "#{aname}: #{String.trim(expr)}"
              {aname, {:string, str, _}, _} -> "#{aname}: #{inspect(str)}"
            end)

          state
          |> region({{meta.line, meta.column - 1}, node_end(meta)}, "{live_render(@socket, #{full}, #{opts})}")
          |> log(
            :info,
            :live_view_tag,
            meta.line,
            "LiveView tag <#{name}> converted to live_render/3"
          )
        else
          log(
            state,
            :manual_required,
            :live_view_tag,
            meta.line,
            "LiveView tag <#{name}> with children — convert to live_render/3 manually"
          )
        end

      :unknown_component ->
        log(
          state,
          :info,
          :unknown_component,
          meta.line,
          "component call site left as-is: <#{name}>"
        )
    end
  end

  defp call_site_close(name, meta, state) do
    case CallSites.resolve(name, state.ctx) do
      :render_suffix ->
        region(state, tag_name_span(meta), name <> ".render")

      {:local_component, fun} ->
        region(state, tag_name_span(meta), ".#{fun}")

      # every live-component open converts to <.live_component> now, so every
      # matching close renames too (slots or not, static or dynamic)
      {:live_component, _full} ->
        case state.pairs[{meta.line, meta.column}] do
          {:close_of, _open_pos} -> region(state, tag_name_span(meta), ".live_component")
          _ -> state
        end

      {:surface_builtin, resolved} ->
        builtin_close(resolved, meta, state)

      _ ->
        state
    end
  end

  ## Form-component mapping (profile builtin_components):
  ## <Form> → <.form>, standalone input controls → <.input type=...>,
  ## <Label> → <.label>. Anything inside a <Field>-style cluster relies on
  ## Surface's form context and stays flagged (structural collapse).

  @field "Surface.Components.Form.Field"
  @inputs "Surface.Components.Form.Inputs"
  @opaque_clusters ~w(Surface.Components.Form.FieldContext)
  @error_tag "Surface.Components.Form.ErrorTag"

  defp builtin_open(resolved, name, attrs, meta, state) do
    spec = form_mapping(state)[resolved]
    binding = field_binding(state)

    cond do
      resolved == @field ->
        field_open(name, attrs, meta, state)

      resolved == @inputs ->
        inputs_open(name, attrs, meta, state)

      resolved in @opaque_clusters ->
        state |> builtin_flag(name, meta) |> push_field(:opaque, meta)

      # inside a converted Field, .input renders errors itself
      resolved == @error_tag and match?({:convertible, _, _}, binding) and meta.self_close ->
        state
        |> region({{meta.line, meta.column - 1}, node_end(meta)}, "")
        |> log(
          :info,
          :error_tag_dropped,
          meta.line,
          "<ErrorTag> dropped — the converted <.input field=...> renders errors itself"
        )

      # plain links only: method/label/event props carry Surface semantics
      spec == :link and binding != :opaque and link_convertible?(attrs) ->
        state
        |> region(tag_name_span(meta), ".link")
        |> form_attrs(attrs, %{"to" => "href"})
        |> then(
          &%{&1 | converted_links: MapSet.put(&1.converted_links, {meta.line, meta.column})}
        )

      # inside a formless Field the controls become bare <input>s — Surface
      # rendered exactly that (`.input` wraps in div+label and rejects
      # type="hidden"); prescan guarantees self-closing + explicit name
      match?({:input, _}, spec) and binding == :formless ->
        {:input, type} = spec
        name_end = {meta.line_end, meta.column_end}

        state
        |> region(tag_name_span(meta), "input")
        |> region({name_end, name_end}, ~s( type="#{type}"))
        |> form_attrs(attrs, %{"selected" => "value"})

      spec == nil or spec == :link or binding == :opaque or
          (match?({:input, _}, spec) and not meta.self_close) ->
        builtin_flag(state, name, meta)

      true ->
        form_open(spec, attrs, meta, state, binding)
    end
  end

  @link_surface_props ~w(method label click click_away capture_click blur focus window_blur window_focus keydown keyup)

  defp link_convertible?(attrs) do
    not Enum.any?(attrs, fn
      {aname, _value, _ameta} -> aname in @link_surface_props
      _other -> false
    end)
  end

  defp builtin_flag(state, name, meta) do
    log(
      state,
      :manual_required,
      :surface_builtin,
      meta.line,
      "Surface built-in <#{name}> left unchanged — map via profile builtin_components or convert manually"
    )
  end

  # a convertible <Field> becomes the <div> Surface rendered anyway; its name attr is deleted (children get explicit field= bindings instead)
  defp field_open(name, attrs, meta, state) do
    case state.clusters.fields[{meta.line, meta.column}] do
      {:convert, access, var} ->
        state
        |> region(tag_name_span(meta), "div")
        |> delete_attr(attrs, "name")
        |> push_field({:convertible, access, var}, meta)

      # no in-template Form, every control self-names (prescan-verified):
      # the name attr fed a context nobody reads — same <div>, no binding
      :formless ->
        state
        |> region(tag_name_span(meta), "div")
        |> delete_attr(attrs, "name")
        |> push_field(:formless, meta)
        |> log(
          :info,
          :field_formless,
          meta.line,
          "<Field> without an in-template <Form> → <div>; its self-named controls become bare <input>s (what Surface rendered)"
        )

      _ ->
        state |> builtin_flag(name, meta) |> push_field(:opaque, meta)
    end
  end

  # <Inputs for={:assoc}> is Surface's wrapper around Phoenix's own
  # <.inputs_for> — convert to it directly, introducing the nested binding
  defp inputs_open(name, attrs, meta, state) do
    case state.clusters.inputs[{meta.line, meta.column}] do
      {:convert, access, var} ->
        name_end = {meta.line_end, meta.column_end}
        nested = FieldClusters.nested_var()

        state
        |> region(tag_name_span(meta), ".inputs_for")
        |> region({name_end, name_end}, " :let={#{nested}} field={#{var}[#{access}]}")
        |> delete_attr(attrs, "for")
        |> push_field({:inputs, nested}, meta)

      _ ->
        state |> builtin_flag(name, meta) |> push_field(:opaque, meta)
    end
  end

  defp builtin_close(resolved, meta, state) do
    spec = form_mapping(state)[resolved]

    cond do
      resolved == @inputs ->
        state =
          if state.clusters.inputs_closes[{meta.line, meta.column}] == :convert,
            do: region(state, tag_name_span(meta), ".inputs_for"),
            else: state

        pop_field(state)

      resolved == @field ->
        state =
          if state.clusters.field_closes[{meta.line, meta.column}] == :convert,
            do: region(state, tag_name_span(meta), "div"),
            else: state

        pop_field(state)

      resolved in @opaque_clusters ->
        pop_field(state)

      field_binding(state) == :opaque ->
        state

      spec == :link ->
        case state.pairs[{meta.line, meta.column}] do
          {:close_of, open_pos} ->
            if MapSet.member?(state.converted_links, open_pos),
              do: region(state, tag_name_span(meta), ".link"),
              else: state

          _ ->
            state
        end

      spec == :form ->
        region(state, tag_name_span(meta), ".form")

      match?({:rename, _}, spec) ->
        {:rename, new} = spec
        region(state, tag_name_span(meta), "." <> new)

      true ->
        state
    end
  end

  defp push_field(state, entry, meta) do
    if meta.self_close,
      do: state,
      else: %{state | field_stack: [entry | state.field_stack]}
  end

  defp pop_field(%{field_stack: [_ | rest]} = state), do: %{state | field_stack: rest}
  defp pop_field(state), do: state

  # nil = not inside a Field; :opaque = inside an unconverted cluster;
  # {:convertible, access, var} = inside a converted Field
  defp field_binding(%{field_stack: []}), do: nil

  defp field_binding(%{field_stack: stack}) do
    if Enum.any?(stack, &(&1 == :opaque)), do: :opaque, else: hd(stack)
  end

  defp delete_attr(state, attrs, name) do
    Enum.reduce(attrs, state, fn
      {^name, value, ameta}, state ->
        region(state, {{ameta.line, max(ameta.column - 1, 1)}, value_end(value, ameta)}, "")

      _attr, state ->
        state
    end)
  end

  ## macro components

  defp macro_open(mname, attrs, meta, state) do
    case macro_mapping(state)[mname] do
      {:component, new_tag, rules} ->
        if macro_convertible?(attrs, rules) do
          state
          |> region(tag_name_span(meta), new_tag)
          |> macro_attrs(attrs, rules)
          # the generic attr pass too (comma/keyword sugar etc.) — rule
          # attrs are literal strings, which it ignores
          |> then(&Enum.reduce(attrs, &1, fn a, st -> attr(a, {mname, meta}, st) end))
        else
          state
          |> macro_flag(mname, meta)
          |> macro_bail(mname, meta)
        end

      _ ->
        state
        |> macro_flag(mname, meta)
        |> macro_bail(mname, meta)
    end
  end

  defp macro_close(mname, meta, state) do
    case {state.macro_bail_stack, macro_mapping(state)[mname]} do
      {[^mname | rest], _} -> %{state | macro_bail_stack: rest}
      {_, {:component, new_tag, _rules}} -> region(state, tag_name_span(meta), new_tag)
      _ -> state
    end
  end

  defp macro_flag(state, mname, meta) do
    log(
      state,
      :manual_required,
      :macro_component,
      meta.line,
      "MacroComponent <##{mname}> left unchanged — not valid HEEx; map via profile macro_components or convert manually"
    )
  end

  defp macro_bail(state, mname, meta) do
    if meta.self_close,
      do: state,
      else: %{state | macro_bail_stack: [mname | state.macro_bail_stack]}
  end

  # {:literal, ...} rules build a new value, so they need a literal string; {:rename, _} only touches the attr NAME, any value (even a dynamic expression) carries over verbatim
  defp macro_convertible?(attrs, rules) do
    Enum.all?(attrs, fn
      {aname, value, _ameta} when is_map_key(rules, aname) ->
        match?({:rename, _}, rules[aname]) or match?({:string, _, _}, value)

      _ ->
        true
    end)
  end

  defp macro_attrs(state, attrs, rules) do
    Enum.reduce(attrs, state, fn
      {aname, value, ameta}, state when is_map_key(rules, aname) ->
        case {rules[aname], value} do
          {{:rename, new}, _} ->
            region(state, attr_name_span(ameta), new)

          {{:literal, new, prefix, suffix}, {:string, text, smeta}} ->
            state
            |> region(attr_name_span(ameta), new)
            |> region(
              {{smeta.line, smeta.column}, {smeta.line_end, smeta.column_end}},
              prefix <> text <> suffix
            )
        end

      _attr, state ->
        state
    end)
  end

  defp macro_mapping(%{ctx: %{profile: %{macro_components: map}}}) when is_map(map), do: map
  defp macro_mapping(_state), do: %{}

  defp form_mapping(%{ctx: %{profile: %{builtin_components: map}}}) when is_map(map), do: map
  defp form_mapping(_state), do: %{}

  defp form_open(:form, attrs, meta, state, _binding) do
    name_end = {meta.line_end, meta.column_end}

    # a convertible Field inside needs a form binding, add :let={form}
    let =
      if MapSet.member?(state.clusters.let_inserts, {meta.line, meta.column}),
        do: " :let={form}",
        else: ""

    state
    |> region(tag_name_span(meta), ".form")
    |> then(fn state ->
      if let == "", do: state, else: region(state, {name_end, name_end}, let)
    end)
    |> form_attrs(attrs, %{"submit" => "phx-submit", "change" => "phx-change"})
  end

  defp form_open({:input, type}, attrs, meta, state, binding) do
    name_end = {meta.line_end, meta.column_end}

    field =
      case binding do
        {:convertible, access, var} -> ~s( field=#{"{"}#{var}[#{access}]#{"}"})
        _ -> ""
      end

    state
    |> region(tag_name_span(meta), ".input")
    |> region({name_end, name_end}, ~s( type="#{type}") <> field)
    |> form_attrs(attrs, %{"selected" => "value"})
  end

  defp form_open({:rename, new}, attrs, meta, state, binding) do
    state = region(state, tag_name_span(meta), "." <> new)

    # a <Label> inside a convertible <Field> — associate it with the control the way Surface's <Label> did (its `for` defaulted to the field's input id), unless it already carries an explicit `for`
    case {new, binding} do
      {"label", {:convertible, access, var}} ->
        if has_attr?(attrs, "for") do
          state
        else
          name_end = {meta.line_end, meta.column_end}
          region(state, {name_end, name_end}, ~s( for=#{"{"}#{var}[#{access}].id#{"}"}))
        end

      _ ->
        state
    end
  end

  defp has_attr?(attrs, name), do: Enum.any?(attrs, fn {a, _v, _m} -> a == name end)

  defp form_attrs(state, attrs, renames) do
    Enum.reduce(attrs, state, fn
      {"opts", {:expr, expr, emeta}, ameta}, state ->
        opts_spread(state, expr, emeta, ameta)

      {aname, _value, ameta}, state when is_map_key(renames, aname) ->
        region(state, attr_name_span(ameta), renames[aname])

      _attr, state ->
        state
    end)
  end

  # `opts={kw_or_expr}` → a root spread: `{expr}` when the expr is a single
  # term, `{[pairs]}` when it's Surface's bare-keyword sugar (bare pairs are
  # not a valid HEEx root expression)
  defp opts_spread(state, expr, emeta, ameta) do
    state = %{state | handled_attrs: MapSet.put(state.handled_attrs, {emeta.line, emeta.column})}
    opts_to_brace = {{ameta.line, ameta.column}, {emeta.line, emeta.column}}

    case Code.string_to_quoted("[#{expr}]") do
      {:ok, [single]} when not (is_tuple(single) and tuple_size(single) == 2) ->
        region(state, opts_to_brace, "{")

      _keyword_or_multi ->
        close_brace = {emeta.line_end, emeta.column_end}

        state
        |> region(opts_to_brace, "{[")
        |> region({close_brace, close_brace}, "]")
    end
  end

  defp slot_children?(%{pairs: pairs}, meta) do
    case pairs[{meta.line, meta.column}] do
      %{slot_children: flag} -> flag
      _ -> false
    end
  end

  defp tag_name_span(meta), do: {{meta.line, meta.column}, {meta.line_end, meta.column_end}}

  ## blocks

  defp block_open("if", expr, span, _meta, state) do
    push(region(state, span, "<%= if #{expr} do %>"), {:if, 0})
  end

  defp block_open("unless", expr, span, _meta, state) do
    push(region(state, span, "<%= if !(#{expr}) do %>"), {:if, 0})
  end

  defp block_open("elseif", expr, span, _meta, state) do
    state = region(state, span, "<% else %><%= if #{expr} do %>")
    [{:if, n} | rest] = state.stack
    %{state | stack: [{:if, n + 1} | rest]}
  end

  defp block_open("else", _expr, span, meta, state) do
    case Map.get(state.index.else_parent, {meta.line, meta.column}) do
      "for" -> region(state, span, "<% end %><% else %>")
      _ -> region(state, span, "<% else %>")
    end
  end

  defp block_open("case", expr, span, _meta, state) do
    push(region(state, span, "<%= case #{expr} do %>"), :case)
  end

  defp block_open("match", expr, span, _meta, state) do
    region(state, span, "<% #{expr} -> %>")
  end

  defp block_open("for", expr, span, meta, state) do
    if MapSet.member?(state.index.for_else, {meta.line, meta.column}) do
      {subject, state} = for_subject(expr, meta, state)

      push(
        region(state, span, "<%= if !Enum.empty?(#{subject}) do %><%= for #{expr} do %>"),
        {:for, true}
      )
    else
      push(region(state, span, "<%= for #{expr} do %>"), {:for, false})
    end
  end

  defp block_close("if", span, state) do
    {{:if, elseifs}, state} = pop(state)
    region(state, span, String.duplicate("<% end %>", elseifs + 1))
  end

  defp block_close(name, span, state) when name in ~w(unless case for) do
    {_entry, state} = pop(state)
    region(state, span, "<% end %>")
  end

  ## attributes (directives)

  # `:hook` compiles in Surface to phx-hook="#{inspect(module)}#name" (bare :hook = "default"), with the module known (from the scan), emit the EXACT registered name so existing collected hooks keep working
  defp attr({":hook", value, ameta}, _tag_meta, %{ctx: %{module: module}} = state)
       when is_binary(module) do
    case value do
      nil ->
        state
        |> region(attr_name_span(ameta), ~s(phx-hook="#{module}#default"))
        |> hook_info(ameta, "#{module}#default")

      {:string, name, smeta} ->
        state
        |> region(attr_name_span(ameta), "phx-hook")
        |> region({{smeta.line, smeta.column}, {smeta.line_end, smeta.column_end}}, "#{module}##{name}")
        |> hook_info(ameta, "#{module}##{name}")

      {:expr, expr, emeta} ->
        # `:hook={"Name", from: Some.Mod}` with literal parts → exact name
        case hook_from_expr(expr) do
          {:ok, hook, mod} ->
            state
            |> region(attr_name_span(ameta), "phx-hook")
            |> region(
              {{emeta.line, emeta.column - 1}, {emeta.line_end, emeta.column_end + 1}},
              ~s("#{mod}##{hook}")
            )
            |> hook_info(ameta, "#{mod}##{hook}")

          :error ->
            hook_flag(state, value, ameta)
        end
    end
  end

  defp attr({":hook", value, ameta}, _tag_meta, state) do
    hook_flag(state, value, ameta)
  end

  defp hook_from_expr(expr) do
    case Code.string_to_quoted("{#{expr}}") do
      {:ok, {hook, [from: {:__aliases__, _, parts}]}} when is_binary(hook) ->
        {:ok, hook, Enum.join(parts, ".")}

      _ ->
        :error
    end
  end

  defp attr({":on-" <> event, _value, ameta}, _tag_meta, state) do
    region(state, attr_name_span(ameta), "phx-#{event}")
  end

  # Surface's own directives — never Alpine binds, so alpine_bind must not
  # rename them (they carry Surface semantics and need manual conversion)
  @surface_directives ~w(:show :values :attrs :props :args)

  defp attr({":" <> bare = name, value, ameta}, {tag_name, tag_meta}, state)
       when name not in @passthrough_directives do
    if alpine_bind?(state) and html_tag?(tag_name) and name not in @surface_directives do
      state
      |> region(attr_name_span(ameta), "x-bind:#{bare}")
      |> log(
        :info,
        :alpine_bind,
        ameta.line,
        "#{name} → x-bind:#{bare} (Alpine bind shorthand; HEEx rejects leading-colon attrs)"
      )
    else
      todo_pos = {tag_meta.line, tag_meta.column - 1}

      state
      |> region({{ameta.line, max(ameta.column - 1, 1)}, value_end(value, ameta)}, "")
      |> region(
        {todo_pos, todo_pos},
        "<%!-- TODO [surface.eject]: removed unsupported directive #{name} --%>"
      )
      |> log(
        :manual_required,
        :unknown_directive,
        ameta.line,
        "unsupported directive #{name} removed"
      )
    end
  end

  # Surface's other spread spelling: `...{expr}` (dots OUTSIDE the braces)
  # tokenizes as a nil-value attr named "...{expr}" — drop the dots
  defp attr({"..." <> rest, nil, ameta}, _tag_meta, state) when rest != "" do
    region(state, attr_name_span(ameta), rest)
  end

  # dynamic attribute NAME (`phx-value-{@ev}={v}`) — Surface tolerated
  # interpolated names, HEEx rejects them; the exact equivalent is a
  # runtime-built map spread: {%{"phx-value-#{@ev}" => v}}
  defp attr({name, value, ameta}, _tag_meta, state)
       when is_binary(name) and value != nil do
    case String.contains?(name, "{") && Regex.run(~r/^(.*?)\{(.+)\}$/, name) do
      [_, prefix, name_expr] ->
        value_text =
          case value do
            {:expr, text, _} -> text
            {:string, text, _} -> inspect(text)
          end

        text = "{%{\"#{prefix}" <> "\#{" <> name_expr <> "}\" => #{value_text}}}"

        state
        |> region({{ameta.line, ameta.column}, value_end(value, ameta)}, text)
        |> log(
          :info,
          :dynamic_attr_name,
          ameta.line,
          "dynamic attribute name #{name} converted to a map spread"
        )

      _ ->
        attr_fallthrough({name, value, ameta}, state)
    end
  end

  defp attr({:root, {:tagged_expr, "...", _expr, marker_meta}, _ameta}, _tag_meta, state) do
    # `{...@opts}` → `{@opts}`: delete just the `...` marker
    region(
      state,
      {{marker_meta.line, marker_meta.column}, {marker_meta.line_end, marker_meta.column_end}},
      ""
    )
  end

  defp attr(attr, _tag_meta, state), do: attr_fallthrough(attr, state)

  # Surface's comma-list attr sugar (`class={"a", "b": cond}`, :css_class / :list props) is NOT valid HEEx, the braces would parse as a tuple and render garbage. Flag rather than silently emit (rewrite to a `[...]`
  # list, keyword pairs as `cond && "class"`).
  defp attr_fallthrough({name, {:expr, expr, emeta}, _ameta}, state) do
    if MapSet.member?(state.handled_attrs, {emeta.line, emeta.column}) do
      state
    else
      flag_comma_list(name, expr, emeta, state)
    end
  end

  defp attr_fallthrough(_attr, state), do: state

  defp hook_info(state, ameta, name) do
    log(
      state,
      :info,
      :hook,
      ameta.line,
      "hook converted to phx-hook=\"#{name}\" (Surface's exact registered name — registration unchanged)"
    )
  end

  defp hook_flag(state, value, ameta) do
    state
    |> region(attr_name_span(ameta), "phx-hook")
    |> log(
      :manual_required,
      :hook,
      ameta.line,
      "hook usage converted to phx-hook#{inspect_value(value)} — verify hook name/registration (module unknown or {name, from: Mod} form)"
    )
  end

  defp alpine_bind?(%{ctx: %{profile: %{alpine_bind: true}}}), do: true
  defp alpine_bind?(_state), do: false

  defp html_tag?(name), do: name =~ ~r/^[a-z]/ and not String.contains?(name, ".")

  defp flag_comma_list(name, expr, emeta, state) do
    cond do
      # an EXPLICIT list literal with a `{atom, _}` keyword pair —
      # `class={["a", "b": cond]}` — is valid HEEx (so it isn't the bare-tuple sugar below), but Phoenix's class handling `to_string`s the keyword tuple and crashes at RUNTIME. It's Surface :css_class semantics, so wrap the whole list in the helper: `class={css_class(["a", "b": cond])}`.
      class_attr?(name) and explicit_css_keyword_list?(expr) ->
        wrap_css_class_list(name, expr, emeta, state)

      true ->
        flag_bare_comma_list(name, expr, emeta, state)
    end
  end

  defp explicit_css_keyword_list?(expr) do
    case Code.string_to_quoted(expr) do
      {:ok, list} when is_list(list) -> Enum.any?(list, &css_keyword_pair?/1)
      _ -> false
    end
  end

  defp css_keyword_pair?({key, _value}) when is_atom(key), do: true
  defp css_keyword_pair?(_), do: false

  defp wrap_css_class_list(name, expr, emeta, state) do
    expr_start = {emeta.line, emeta.column}
    expr_end = {emeta.line_end, emeta.column_end}

    case css_class_helper(state) do
      helper when is_binary(helper) ->
        state
        |> region({expr_start, expr_start}, "#{helper}(")
        |> region({expr_end, expr_end}, ")")
        |> log(
          :info,
          :css_class_wrapped,
          emeta.line,
          "#{name} list with {class, cond} keyword pairs wrapped in #{helper}(...) (Surface :css_class semantics; Phoenix's class handling crashes on the keyword tuple)"
        )

      _ ->
        log(
          state,
          :warning,
          :css_class_no_helper,
          emeta.line,
          "#{name} list has {class, cond} keyword pairs that crash Phoenix's class handling — configure a css_class_helper or rewrite the pairs as `cond && \"class\"`"
        )
    end
  end

  defp flag_bare_comma_list(name, expr, emeta, state) do
    case Code.string_to_quoted("[#{expr}]") do
      # single bare keyword pair (`class={hidden: @cw}`) is the same sugar —
      # but a real tuple literal (`{{:ok, 1}}`, source starts with `{`) isn't
      {:ok, [{key, _value}] = list} when is_atom(key) ->
        if String.starts_with?(String.trim_leading(expr), "{"),
          do: state,
          else: comma_list(name, expr, emeta, state, list)

      {:ok, list} when is_list(list) and length(list) > 1 ->
        comma_list(name, expr, emeta, state, list)

      _ ->
        state
    end
  end

  defp comma_list(name, _expr, emeta, state, _list) do
    helper = css_class_helper(state)

    if helper && class_attr?(name) do
      # `class={a, b, c: cond}` → `class={helper([a, b, c: cond])}` —
      # valid HEEx, identical Surface :css_class semantics at runtime
      expr_start = {emeta.line, emeta.column}
      expr_end = {emeta.line_end, emeta.column_end}

      state
      |> region({expr_start, expr_start}, "#{helper}([")
      |> region({expr_end, expr_end}, "])")
      |> log(
        :info,
        :css_class_wrapped,
        emeta.line,
        "#{name} comma-list wrapped in #{helper}([...]) (Surface :css_class semantics)"
      )
    else
      # non-class comma/keyword sugar: Surface's :keyword/:list prop
      # semantics — a plain list literal is the exact equivalent. For CLASS
      # attrs without a css_class_helper it still compiles but keyword pairs
      # lose their conditional meaning → warning, not info
      expr_start = {emeta.line, emeta.column}
      expr_end = {emeta.line_end, emeta.column_end}

      {severity, category, message} =
        if class_attr?(name) do
          {:warning, :css_class_no_helper,
           "#{name} sugar wrapped as a list WITHOUT a css_class_helper — keyword pairs lose their conditional meaning; configure the helper or rewrite"}
        else
          {:info, :attr_list_wrapped, "#{name} comma/keyword sugar wrapped as a list literal"}
        end

      state
      |> region({expr_start, expr_start}, "[")
      |> region({expr_end, expr_end}, "]")
      |> log(severity, category, emeta.line, message)
    end
  end

  defp class_attr?(name), do: name == "class" or String.ends_with?(name, "_class")

  defp css_class_helper(%{ctx: %{profile: %{css_class_helper: helper}}}), do: helper
  defp css_class_helper(_state), do: nil

  ## helpers

  defp expr_text(nil), do: nil
  defp expr_text({:expr, text, _meta}), do: text

  # the whole `{#name expr}` / `{#name}` marker span (end-exclusive)
  defp block_span({:expr, _text, emeta}, meta, _state) do
    {{meta.line, meta.column - 2}, {emeta.line_end, emeta.column_end + 1}}
  end

  defp block_span(nil, meta, state) do
    # nil-expr blocks ({#else}): name column_end normally points at `}`;
    # scan forward if whitespace precedes it ({#else }, legal)
    close = scan_to_close(state, {meta.line_end, meta.column_end})
    {{meta.line, meta.column - 2}, close}
  end

  defp scan_to_close(state, {line, col}) do
    offset = Splicer.pos_to_offset(state.offsets, {line, col})

    case String.at(state.source, offset) do
      "}" -> {line, col + 1}
      _ -> scan_to_close(state, {line, col + 1})
    end
  end

  defp node_end(%{self_close: true} = meta), do: {meta.node_line_end, meta.node_column_end + 2}
  defp node_end(meta), do: {meta.node_line_end, meta.node_column_end + 1}

  defp attr_name_span(ameta), do: {{ameta.line, ameta.column}, {ameta.line_end, ameta.column_end}}

  defp value_end(nil, ameta), do: {ameta.line_end, ameta.column_end}
  defp value_end({:expr, _t, em}, _ameta), do: {em.line_end, em.column_end + 1}
  defp value_end({:string, _t, sm}, _ameta), do: {sm.line_end, sm.column_end + 1}

  defp for_subject(expr, meta, state) do
    case String.split(expr, "<-", parts: 2) do
      [_lhs, rhs] ->
        subject = String.trim(rhs)

        cond do
          String.contains?(subject, "<-") or String.contains?(subject, ",") ->
            {subject,
             log(
               state,
               :manual_required,
               :for_else_double_eval,
               meta.line,
               "for-else with multi-generator/filtered comprehension — Enum.empty? wrap may be wrong: #{expr}"
             )}

          not Regex.match?(~r/^@\w+$/, subject) ->
            {subject,
             log(
               state,
               :warning,
               :for_else_double_eval,
               meta.line,
               "for-else subject is not a plain assign — it will be evaluated twice: #{subject}"
             )}

          true ->
            {subject, state}
        end

      _ ->
        {"[]",
         log(
           state,
           :manual_required,
           :for_else_double_eval,
           meta.line,
           "for-else generator not parseable, emitted always-true wrap: #{expr}"
         )}
    end
  end

  defp inspect_value({:string, s, _}), do: " (#{inspect(s)})"
  defp inspect_value(_), do: ""

  defp region(state, {start_pos, end_pos}, text) do
    %{state | regions: [{start_pos, end_pos, text} | state.regions]}
  end

  defp push(state, entry), do: %{state | stack: [entry | state.stack]}
  defp pop(%{stack: [top | rest]} = state), do: {top, %{state | stack: rest}}

  defp log(state, severity, category, line, message) do
    entry = %LogEntry{
      phase: :template,
      severity: severity,
      category: category,
      file: state.ctx.file,
      line: line,
      message: message
    }

    %{state | logs: [entry | state.logs]}
  end
end
