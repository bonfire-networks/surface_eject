defmodule SurfaceEject.Profiles.Bonfire do
  @moduledoc """
  The [Bonfire](https://bonfirenetworks.org) profile — the migration this
  tool was extracted from, kept as a worked example of a real-world
  `SurfaceEject.Profile`. Selected with `--profile bonfire`.
  """

  alias SurfaceEject.Profile

  def profile do
    %Profile{
      declarations: :compat,
      web_module: :preserve,
      remote_call: :render,
      web_macros: %{
        stateless_component: :function_component,
        stateful_component: :live_component,
        surface_live_view: :live_view
      },
      # converted modules must compile through the context-lib-wired PLAIN
      # macros (the Surface atoms keep the Surface stack for unconverted
      # extensions during incremental migration) — one-token use-line rewrite
      use_atom_map: %{
        stateless_component: :function_component,
        stateful_component: :live_component,
        surface_live_view: :live_view
      },
      # macros that take web-macro atoms like `use` does (Bonfire's LVN variant)
      use_like_macros: [:use_if_enabled],
      dynamic_dispatch: %{
        "StatelessComponent" => :suffix_render,
        "StatefulComponent" => :suffix_render
      },
      # Bonfire's web.ex surface_helpers provide exactly Surface's own
      # component library as aliases
      aliases: SurfaceEject.Profiles.Default.builtin_aliases(),
      context: :library
    }
  end
end
