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
  alias SurfaceEject.Template.{BlockIndex, CallSites, Slots, Splicer}

  # directives that are valid HEEx as-is
  @passthrough_directives ~w(:if :for :let)

  @doc """
  Converts Surface template `source` to HEEx.

  Returns `{output, logs}`.
  """
  def convert(source, %Context{} = ctx \\ %Context{}) do
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

  defp token({:tag_open, name, attrs, meta}, state) do
    state = call_site_open(name, meta, state)
    Enum.reduce(attrs, state, &attr(&1, meta, &2))
  end

  defp token({:tag_close, name, meta}, state) do
    call_site_close(name, meta, state)
  end

  defp token(_other, state), do: state

  ## component call sites (M3)

  defp call_site_open(name, meta, state) do
    case CallSites.resolve(name, state.ctx) do
      :skip ->
        state

      :render_suffix ->
        region(state, tag_name_span(meta), name <> ".render")

      {:live_component, full} ->
        if slot_children?(state, meta) do
          log(
            state,
            :manual_required,
            :live_component_slots,
            meta.line,
            "<#{name}> passes slot entries — <.live_component> cannot receive them; left unchanged (convert callers after redesign, or the callee's slots)"
          )
        else
          region(state, tag_name_span(meta), ".live_component module={#{full}}")
        end

      :surface_builtin ->
        log(
          state,
          :manual_required,
          :surface_builtin,
          meta.line,
          "Surface built-in <#{name}> left unchanged — map via profile form_components or convert manually"
        )

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

      {:live_component, _full} ->
        case state.pairs[{meta.line, meta.column}] do
          {:close_of, open_pos} ->
            if get_in(state.pairs, [open_pos, :slot_children]),
              do: state,
              else: region(state, tag_name_span(meta), ".live_component")

          _ ->
            state
        end

      _ ->
        state
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

  defp attr({":hook", value, ameta}, _tag_meta, state) do
    state
    |> region(attr_name_span(ameta), "phx-hook")
    |> log(
      :manual_required,
      :hook,
      ameta.line,
      "hook usage converted to phx-hook#{inspect_value(value)} — verify hook registration (colocated hooks migration is manual in MVP)"
    )
  end

  defp attr({":on-" <> event, _value, ameta}, _tag_meta, state) do
    region(state, attr_name_span(ameta), "phx-#{event}")
  end

  defp attr({":" <> _ = name, value, ameta}, tag_meta, state)
       when name not in @passthrough_directives do
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

  defp attr({:root, {:tagged_expr, "...", _expr, marker_meta}, _ameta}, _tag_meta, state) do
    # `{...@opts}` → `{@opts}`: delete just the `...` marker
    region(
      state,
      {{marker_meta.line, marker_meta.column}, {marker_meta.line_end, marker_meta.column_end}},
      ""
    )
  end

  # Surface's comma-list attr sugar (`class={"a", "b": cond}`, :css_class / :list props) is NOT valid HEEx, the braces would parse as a tuple and render garbage. Flag rather than silently emit (rewrite to a `[...]`
  # list, keyword pairs as `cond && "class"`).
  defp attr({name, {:expr, expr, emeta}, _ameta}, _tag_meta, state) do
    case Code.string_to_quoted("[#{expr}]") do
      {:ok, list} when is_list(list) and length(list) > 1 ->
        log(
          state,
          :manual_required,
          :attr_comma_list,
          emeta.line,
          "#{name}={#{expr}} uses Surface's comma-list sugar — invalid HEEx (parses as a tuple); " <>
            "rewrite as a list: #{name}={[...]} with keyword pairs as `cond && \"class\"`"
        )

      _ ->
        state
    end
  end

  defp attr(_attr, _tag_meta, state), do: state

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
