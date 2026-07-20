defmodule SurfaceEject.Profiles do
  @moduledoc """
  Built-in profile registry, shared by both frontends (the Igniter mix task and the escript CLI). Returns `nil` for unknown names so each frontend can
  fall back to its own custom-profile mechanism (a project module exposing `profile/0` for the mix task, a `.exs` file for the escript).
  """

  def builtin(name) when name in [nil, "default"], do: SurfaceEject.Profiles.Default.profile()
  def builtin("bonfire"), do: SurfaceEject.Profiles.Bonfire.profile()
  def builtin(_other), do: nil
end