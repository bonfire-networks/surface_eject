defmodule SurfaceEject.Profile do
  @moduledoc """
  Project-specific conversion policy. The generic core stays project-agnostic;
  everything opinionated lives here.

    * `:declarations` — what to do with `prop`/`data`/`slot` in `.ex` files:
      `:attr` (generic: convert to `attr`/`slot` where safely adjacent to a
      1-arity def) or `:compat` (leave untouched — for projects whose macro
      layer supplies compat semantics, e.g. Bonfire).
    * `:web_module` — `:rewrite` (generic) or `:preserve` (web-macro `use`
      lines untouched).
    * `:remote_call` — call-site convention: `:render` (safe default) or
      `:snake_name` (post-MVP).

  Built-in profiles are separate modules under `SurfaceEject.Profiles.*`
  (e.g. `SurfaceEject.Profiles.Bonfire`), each exposing `profile/0`. To use
  your own, define such a module in your project and pass its name:

      mix surface.eject --profile MyApp.EjectProfile
  """

  defstruct declarations: :attr,
            web_module: :rewrite,
            remote_call: :render,
            # web-macro atom → component type (`use MyWeb, :atom` shorthand resolution)
            web_macros: %{},
            # web-macro atom rewrites for CONVERTED modules (Surface atom → plain-stack atom)
            use_atom_map: %{},
            # additional use-like macros whose atom arg gets the same rewrite
            use_like_macros: [],
            # tag name → :suffix_render for project dynamic-dispatch wrappers
            dynamic_dispatch: %{},
            # statically-known aliases provided by web macros (merged with scanned ones)
            aliases: %{},
            form_components: %{},
            context: :flag_all
end
