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
    if meta[:self_close] do
      {stack, acc}
    else
      case builtin(name, ctx) do
        @form ->
          {[{:form, pos(meta), let_var(attrs)} | stack], acc}

        @field ->
          cluster_open(:field, "name", :fields, attrs, meta, stack, acc)

        @inputs ->
          cluster_open(:inputs, "for", :inputs, attrs, meta, stack, acc)

        _ ->
          {stack, acc}
      end
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
    with {:ok, access} <- attr_access(attrs, attr_name),
         {:ok, form_pos, var, needs_let?} <- nearest_form(stack) do
      acc = put_in(acc[acc_key][pos(meta)], {:convert, access, var})

      acc =
        if needs_let? and form_pos,
          do: update_in(acc.let_inserts, &MapSet.put(&1, form_pos)),
          else: acc

      {[{kind, pos(meta), :convert} | stack], acc}
    else
      _ -> {[{kind, pos(meta), nil} | stack], acc}
    end
  end

  defp cluster_close(kind, acc_key, meta, stack, acc) do
    case Enum.split_while(stack, &(elem(&1, 0) != kind)) do
      {skipped, [{^kind, _open_pos, :convert} | rest]} ->
        {skipped ++ rest, put_in(acc[acc_key][pos(meta)], :convert)}

      {skipped, [{^kind, _pos, _} | rest]} ->
        {skipped ++ rest, acc}

      _ ->
        {stack, acc}
    end
  end

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