defmodule SurfaceEject.Ex.TypeTable do
  @moduledoc """
  Surface prop type → Phoenix `attr` type mapping (see the conversion spec).
  Returns `{phoenix_type, log_category | nil}`.
  """

  def map(:event), do: {:string, :event_prop}
  def map(:fun), do: {:any, :fun_prop}
  def map(:css_class), do: {:any, nil}
  def map(:generator), do: {:list, nil}
  def map(type) when type in ~w(string boolean integer float atom list map any)a, do: {type, nil}
  def map(_other), do: {:any, :unknown_prop_type}
end
