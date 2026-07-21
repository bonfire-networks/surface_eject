defmodule SurfaceEject.Runtime do
  @moduledoc """
  Reference implementations of the tiny runtime helpers converted templates may call. The converter never *requires* them, but some transforms (like `css_class_helper`) emit calls to a function you provide.

  Since surface_eject is usually a dev-only dependency (`only: :dev, runtime: false`), the recommended setup is to **vendor** the helper: copy the function below into a module your templates already import (e.g. your core components) and set the profile's `css_class_helper` to its bare name. If you keep surface_eject as a full runtime dependency instead, you can point the profile straight at `"SurfaceEject.Runtime.css_class"`.
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
end
