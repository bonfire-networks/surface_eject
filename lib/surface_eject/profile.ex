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
            builtin_components: %{},
            # local function calls to rename in converted modules (e.g.
            # Surface-era helpers → their plain-stack analogues)
            call_renames: %{},
            # :native mode — does the project use surf_live_attr? true emits
            # active `live_attr` lines for stateful/internal declarations;
            # false emits the same translation COMMENTED (file compiles, the
            # manual step is pre-written)
            live_attr: false,
            # :native mode — function name the emitted delegating render
            # calls for embedded-template modules (e.g. "render_template" for
            # Bonfire's web.ex convention); nil falls back to flagging
            embedded_render_delegate: nil,
            # "#Tag" (without the #) → {:component, "New.tag", attr_rules}; attr_rules: %{"attr" => {:rename, "new"} | {:literal, "new", prefix, suffix}} ({:literal, ...} rewrites a literal string value with prefix/suffix, MacroComponent static props are always literals)
            macro_components: %{},
            # helper (a function name available where converted templates compile, e.g. via your web-macro imports) that implements Surface's :css_class semantics; when set, comma-list class attrs rewrite to `class={helper([...])}` instead of flagging
            css_class_helper: nil,
            # rename unknown leading-colon attrs on HTML tags to Alpine's x-bind: longhand (`:class` → `x-bind:class`) instead of removing them, for projects using Alpine's bind shorthand, which Surface passed through but HEEx rejects
            alpine_bind: false,
            context: :flag_all
end
