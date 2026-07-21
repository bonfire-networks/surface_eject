defmodule SurfaceEject.Template.FieldClusters do
  @moduledoc """
  Pre-pass for Field conversion: pairs each `<Field>` with its enclosing in-template `<Form>` and computes the form binding. A Field is convertible when it has a `name` attr AND an enclosing Form whose `:let` (if any) is a simple var, the transform then keeps structure: `Field` → `<div>` (Surface's Field rendered exactly that), child controls gain `field={var[name]}`, and the Form gains `:let={form}` if it had none.
  """

  alias SurfaceEject.Template.CallSites

  @form "Surface.Components.Form"
  @field "Surface.Components.Form.Field"
  @inputs "Surface.Components.Form.Inputs"

  # the nested form binding introduced by a converted <Inputs> (mirrors Surface's own internal name); sibling/nested blocks shadow it safely
  @nested_var "nested_form"

  @doc """
  Returns `%{fields:, field_closes:, inputs:, inputs_closes:, let_inserts:}`
  — open/close positions of convertible `<Field>`/`<Inputs>` plus the Form
  open positions needing a `:let={form}` insertion.
  """
  def prescan(tokens, ctx) do
    acc = %{
      fields: %{},
      field_closes: %{},
      inputs: %{},
      inputs_closes: %{},
      let_inserts: MapSet.new()
    }

    {_stack, acc} = Enum.reduce(tokens, {[], acc}, &token(&1, &2, ctx))
    acc
  end

  defp token({:tag_open, name, attrs, meta}, {stack, acc}, ctx) do
    resolved = builtin(name, ctx)

    cond do
      meta[:self_close] ->
        {stack, validate_formless_child(resolved, attrs, true, stack, acc, ctx)}

      resolved == @form ->
        {[{:form, pos(meta), let_var(attrs)} | stack], acc}

      resolved == @field ->
        cluster_open(:field, "name", :fields, attrs, meta, stack, acc)

      resolved == @inputs ->
        cluster_open(:inputs, "for", :inputs, attrs, meta, stack, acc)

      true ->
        {stack, validate_formless_child(resolved, attrs, false, stack, acc, ctx)}
    end
  end

  defp token({:tag_close, name, meta}, {stack, acc}, ctx) do
    case builtin(name, ctx) do
      @form -> {pop(stack, :form), acc}
      @field -> cluster_close(:field, :field_closes, meta, stack, acc)
      @inputs -> cluster_close(:inputs, :inputs_closes, meta, stack, acc)
      _ -> {stack, acc}
    end
  end

  defp token(_other, state, _ctx), do: state

  defp cluster_open(kind, attr_name, acc_key, attrs, meta, stack, acc) do
    case {attr_access(attrs, attr_name), nearest_form(stack)} do
      {{:ok, access}, {:ok, form_pos, var, needs_let?}} ->
        acc = put_in(acc[acc_key][pos(meta)], {:convert, access, var})

        acc =
          if needs_let? and form_pos,
            do: update_in(acc.let_inserts, &MapSet.put(&1, form_pos)),
            else: acc

        {[{kind, pos(meta), :convert} | stack], acc}

      {{:ok, _access}, :error} when kind == :field ->
        # no in-template Form at all: Surface rendered Field as a plain <div>
        # and never needed a form binding when every control names itself —
        # tentatively convertible; any child that would rely on the Field's
        # context name invalidates it (validate_formless_child)
        acc = put_in(acc[acc_key][pos(meta)], :formless)
        {[{kind, pos(meta), :formless} | stack], acc}

      _ ->
        {[{kind, pos(meta), nil} | stack], acc}
    end
  end

  defp cluster_close(kind, acc_key, meta, stack, acc) do
    open_key = if kind == :field, do: :fields, else: :inputs

    case Enum.split_while(stack, &(elem(&1, 0) != kind)) do
      {skipped, [{^kind, open_pos, marker} | rest]} when marker != nil ->
        # the open entry may have been invalidated mid-walk (formless)
        acc =
          if Map.has_key?(acc[open_key], open_pos),
            do: put_in(acc[acc_key][pos(meta)], :convert),
            else: acc

        {skipped ++ rest, acc}

      {skipped, [{^kind, _pos, _} | rest]} ->
        {skipped ++ rest, acc}

      _ ->
        {stack, acc}
    end
  end

  # a Surface form builtin inside a tentatively-formless Field: convertible
  # only as a bare self-closing <input>-element control that names itself —
  # anything else (Label/ErrorTag/select/textarea/unnamed) needs the Field's
  # context binding, so the whole formless Field falls back to the flag
  defp validate_formless_child(nil, _attrs, _self_close?, _stack, acc, _ctx), do: acc

  defp validate_formless_child(resolved, attrs, self_close?, stack, acc, ctx) do
    case nearest_field(stack) do
      {:ok, fpos, :formless} ->
        if formless_ok?(resolved, attrs, self_close?, ctx),
          do: acc,
          else: %{acc | fields: Map.delete(acc.fields, fpos)}

      _ ->
        acc
    end
  end

  defp nearest_field([{:field, fpos, marker} | _rest]), do: {:ok, fpos, marker}
  defp nearest_field([{:form, _, _} | _rest]), do: :error
  defp nearest_field([{:inputs, _, _} | _rest]), do: :error
  defp nearest_field([_other | rest]), do: nearest_field(rest)
  defp nearest_field([]), do: :error

  defp formless_ok?(resolved, attrs, true = _self_close?, ctx) do
    case form_mapping(ctx)[resolved] do
      {:input, type} when type not in ["select", "textarea"] -> named?(attrs)
      _ -> false
    end
  end

  defp formless_ok?(_resolved, _attrs, _self_close?, _ctx), do: false

  defp named?(attrs) do
    Enum.any?(attrs, fn
      {"name", value, _ameta} -> value != nil
      _other -> false
    end)
  end

  defp form_mapping(%{profile: %{builtin_components: map}}) when is_map(map), do: map
  defp form_mapping(_ctx), do: %{}

  defp attr_access(attrs, attr_name) do
    Enum.find_value(attrs, :error, fn
      {^attr_name, {:expr, text, _}, _} -> {:ok, String.trim(text)}
      {^attr_name, {:string, s, _}, _} -> {:ok, inspect(s)}
      _ -> nil
    end)
  end

  # the nearest form binding: an enclosing <Form> (its :let var, or "form"
  # with a :let insertion) or a convertible <Inputs> (its nested var)
  defp nearest_form([{:form, pos, nil} | _rest]), do: {:ok, pos, "form", true}

  defp nearest_form([{:form, pos, var} | _rest]) when is_binary(var),
    do: {:ok, pos, var, false}

  # complex :let pattern — can't reference the binding
  defp nearest_form([{:form, _pos, _complex} | _rest]), do: :error
  defp nearest_form([{:inputs, _pos, :convert} | _rest]), do: {:ok, nil, @nested_var, false}
  defp nearest_form([{:inputs, _pos, _} | _rest]), do: :error
  defp nearest_form([_other | rest]), do: nearest_form(rest)
  defp nearest_form([]), do: :error

  def nested_var, do: @nested_var

  # existing `:let={f}` — usable only when it's a bare var
  defp let_var(attrs) do
    Enum.find_value(attrs, fn
      {":let", {:expr, text, _}, _} ->
        text = String.trim(text)
        if text =~ ~r/^[a-z_][A-Za-z0-9_]*$/, do: text, else: :complex

      _ ->
        nil
    end)
  end

  defp pop(stack, kind) do
    case Enum.split_while(stack, &(elem(&1, 0) != kind)) do
      {skipped, [_ | rest]} -> skipped ++ rest
      _ -> stack
    end
  end

  defp builtin(name, ctx) do
    case CallSites.resolve(name, ctx) do
      {:surface_builtin, resolved} -> resolved
      _ -> nil
    end
  end

  defp pos(meta), do: {meta.line, meta.column}
end