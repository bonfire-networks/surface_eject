defmodule SurfaceEject.Context do
  @moduledoc """
  Conversion context threaded through the transforms: the active profile,
  the project-wide type map (module → `:function_component | :live_component |
  :live_view`), harvested aliases, and the current file.

  In M1 the type map is empty — component call sites are left untouched and
  logged as `:unknown_component`.
  """

  defstruct profile: nil,
            type_map: %{},
            aliases: %{},
            file: "nofile",
            ext: ".sface",
            opts: []
end
