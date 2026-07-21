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
    if source =~ "Surface.LiveViewTest" or source =~ "render_surface" do
      # Surface's TEST harness (`render_surface do ~F"..." end`): the sigil
      # only exists inside Surface's own macro — renaming it to ~H would
      # neither compile (no sigil_H import) nor mean anything to
      # render_surface. Left for hand-conversion (render_component/2)
      {source,
       [
         %SurfaceEject.LogEntry{
           phase: :ex,
           severity: :manual_required,
           category: :render_surface,
           file: ctx.file,
           line: 1,
           message:
             "module uses Surface.LiveViewTest/render_surface — left unconverted; port tests to Phoenix.LiveViewTest.render_component/2 by hand"
         }
       ]}
    else
      {source, def_logs} = Definitions.convert(source, ctx)
      {source, sigil_logs} = Sigils.convert(source, ctx)
      {source, def_logs ++ sigil_logs}
    end
  end
end
