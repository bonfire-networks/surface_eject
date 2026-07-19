defmodule SurfaceEject.Template.Slots do
  @moduledoc """
  Rewrites Surface's `<#slot>` element form (the only slot-render form in
  real-world usage; the `{#slot}` block form is unused) to HEEx:

    * `<#slot />`                → `{render_slot(@inner_block)}`
    * `<#slot {@name} />`        → `{render_slot(@name)}`
    * `<#slot {@col, item} />`   → `{render_slot(@col, item)}`
    * `<#slot {@name}>F</#slot>` → `<%= if @name && @name != [] do %>{render_slot(@name)}<% else %>F<% end %>`
      (fallback children render only when no slot entry was passed)
  """

  @doc "The render expression for a slot ref (`nil` = default slot)."
  def render_expr(nil), do: "{render_slot(@inner_block)}"
  def render_expr(ref), do: "{render_slot(#{ref})}"

  @doc "Replacement for a self-closing `<#slot ... />`."
  def self_close(ref), do: render_expr(ref)

  @doc "Replacement for the open tag of a `<#slot ...>` with fallback children."
  def open_with_fallback(ref) do
    check = check_expr(ref)
    "<%= if #{check} && #{check} != [] do %>#{render_expr(ref)}<% else %>"
  end

  @doc "Replacement for `</#slot>`."
  def close_tag, do: "<% end %>"

  @doc "Extracts the slot ref expression from a `<#slot>` tag's attrs (nil for default)."
  def ref_from_attrs(attrs) do
    Enum.find_value(attrs, fn
      {:root, {:expr, expr, _}, _} -> String.trim(expr)
      _ -> nil
    end)
  end

  # the slot itself (before any :let-style args after a comma)
  defp check_expr(nil), do: "@inner_block"
  defp check_expr(ref), do: ref |> String.split(",", parts: 2) |> hd() |> String.trim()
end
