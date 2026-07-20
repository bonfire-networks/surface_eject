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
      # Bonfire's web.ex surface_helpers provide Surface's own component
      # library PLUS a handful of Bonfire components as macro-quoted aliases
      # (invisible to the per-file alias scan) — web.ex:930-933
      aliases:
        Map.merge(SurfaceEject.Profiles.Default.builtin_aliases(), %{
          "LazyImage" => "Bonfire.UI.Common.LazyImage",
          "LinkLive" => "Bonfire.UI.Common.LinkLive",
          "LinkPatchLive" => "Bonfire.UI.Common.LinkPatchLive",
          "Dropdown" => "Bonfire.UI.Common.DropdownLive"
        }),
      # Bonfire's CoreComponents follow the phx.new shape (.form/.input/.label)
      builtin_components: SurfaceEject.Profiles.Default.builtin_components_core(),
      # iconify_ex's <#Icon> macro → its own plain function component;
      # shorthand expansions mirror Iconify.Icon.prepare_icon_name/1
      macro_components: %{
        "Icon" =>
          {:component, "Iconify.iconify",
           %{
             "iconify" => {:rename, "icon"},
             "icon" => {:rename, "icon"},
             "solid" => {:literal, "icon", "heroicons:", "-solid"},
             "outline" => {:literal, "icon", "heroicons:", ""},
             "mini" => {:literal, "icon", "heroicons:", "-20-solid"},
             "micro" => {:literal, "icon", "heroicons:", "-16-solid"}
           }}
      },
      # OpenModalLive callers pass slot entries; its open_modal/1
      # function-component entry point (see plan) forwards them as assigns
      live_component_slot_entrypoints: %{
        "Bonfire.UI.Common.OpenModalLive" => "open_modal"
      },
      # Bonfire templates use Alpine's bind shorthand (`:class=`, `:aria-*=`)
      alpine_bind: true,
      # vendored in Bonfire.UI.Common.CoreComponents (imported by the web macros), same semantics as Surface's :css_class
      css_class_helper: "css_class",
      context: :library
    }
  end
end
