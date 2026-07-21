defmodule SurfaceEject.Runtime do
  @moduledoc """
  Reference implementations of the tiny runtime helpers converted templates may call. The converter never *requires* them, but some transforms (like `css_class_helper`) emit calls to a function you provide.

  Since surface_eject is usually a dev-only dependency (`only: :dev, runtime: false`), the recommended setup is to **vendor** the helpers: copy the ones you need below into a module your templates already import (e.g. your core components) and point the relevant profile field at their bare names. If you keep surface_eject as a full runtime dependency instead, you can point the profile straight at `"SurfaceEject.Runtime.css_class"` etc.
  """

  @doc """
  Joins a list of CSS classes with Surface's `:css_class` semantics (mirrors `Surface.TypeHandler.CssClass`): strings/atoms are split on whitespace, `{class, boolean-ish}` pairs are included unless the value is `nil` or `false`, and nested lists flatten.

  ## Examples

      iex> SurfaceEject.Runtime.css_class(["card", "max-w-sm", "rounded-2xl": true])
      "card max-w-sm rounded-2xl"

      iex> SurfaceEject.Runtime.css_class(["a b", nil, "c-1": false, "d-2": 1])
      "a b d-2"

      iex> SurfaceEject.Runtime.css_class([["a", b: true], "c"])
      "a b c"
  """
  def css_class(value) when is_list(value) do
    value |> collect_css_classes([]) |> Enum.reverse() |> Enum.join(" ")
  end

  defp collect_css_classes(list, acc) do
    Enum.reduce(list, acc, fn
      nested, acc when is_list(nested) -> collect_css_classes(nested, acc)
      {class, val}, acc when val not in [nil, false] -> add_css_class(acc, class)
      {_class, _falsy}, acc -> acc
      class, acc when is_binary(class) or is_atom(class) -> add_css_class(acc, class)
      _other, acc -> acc
    end)
  end

  defp add_css_class(acc, class) do
    (class |> to_string() |> String.split(" ", trim: true) |> Enum.reverse()) ++ acc
  end

  @doc """
  A function component that renders another function component chosen at runtime, the plain-LiveView replacement for Surface's dynamic dispatch (`<Surface.Components.Dynamic.Component module={...}>`). Phoenix ships no built-in for it, but documents [`apply/3` dynamic-rendering pattern](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html#module-dynamic-component-rendering).

  Point the profile's `dynamic_dispatch` at a call to this (or a vendored copy imported by your templates, so it reads as `<.dynamic_component module={...}>`). `module` is applied as a function component, its `render/1` or `@function`, with the remaining assigns and slots forwarded; it is expected to be already resolved at the call site (so pass a real module, e.g. via your own enable-check helper). A stateful `<StatefulComponent>` maps instead to Phoenix's own `<.live_component module={...}>`, which takes a dynamic module natively, no helper needed.
  """
  def dynamic_component(%{module: mod} = assigns) do
    {mod, assigns} = Map.pop(assigns, :module)
    {fun, assigns} = Map.pop(assigns, :function, :render)
    apply(mod, fun, [assigns])
  end

  @doc """
  Embeds the module's colocated `.heex` template (named after the module's underscored leaf: `MyApp.CardLive` → `card_live.heex`, next to the `.ex` file) and exposes it as `render_template/1` — the target of the `def render(assigns), do: render_template(assigns)` delegation the converter emits for embedded-template modules (profile `embedded_render_delegate: "render_template"`).

  Call it from your web macros (or directly in a module) after `use Phoenix.Component`:

      defmodule MyAppWeb do
        def component do
          quote do
            use Phoenix.Component
            require SurfaceEject.Runtime
            SurfaceEject.Runtime.embed_colocated_template()
          end
        end
      end

  No-op when no colocated template exists. NOTE: `embed_templates` patterns are extension-less (Phoenix appends the engine extensions itself).
  """
  defmacro embed_colocated_template(opts \\ []) do
    quote do
      template_name =
        __MODULE__ |> Module.split() |> List.last() |> Macro.underscore()

      case Phoenix.Component.embed_templates(template_name, unquote(opts)) do
        [{template_fun, _path} | _] ->
          @__colocated_template_fun__ String.to_existing_atom(template_fun)
          def render_template(assigns),
            do: apply(__MODULE__, @__colocated_template_fun__, [assigns])

        [] ->
          nil
      end
    end
  end
end
