defmodule SurfaceEject.Ex do
  @moduledoc """
  The `.ex` file conversion pass: Surface declarations (via Sourceror
  range-patches) and `~F` sigil bodies (via the template pass), policy-driven
  by `SurfaceEject.Profile`.

  In Bonfire-style `:compat` mode the declaration pass is a no-op and the
  only delta is `~F` → `~H` with converted template bodies.
  """

  alias SurfaceEject.Context
  alias SurfaceEject.Ex.{Definitions, Sigils}

  @doc "Returns `{converted_source, logs}`."
  def convert(source, %Context{} = ctx \\ %Context{}) do
    {source, def_logs} = Definitions.convert(source, ctx)
    {source, sigil_logs} = Sigils.convert(source, ctx)
    {source, def_logs ++ sigil_logs}
  end
end
