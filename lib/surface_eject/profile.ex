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

  def bonfire do
    %__MODULE__{
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
      # Surface-builtin aliases provided by Bonfire's web.ex surface_helpers —
      # lets call-site resolution flag them as :surface_builtin
      aliases:
        Map.new(
          ~w(Field FieldContext Label ErrorTag Inputs HiddenInput HiddenInputs TextInput TextArea NumberInput RadioButton Select MultipleSelect OptionsForSelect DateTimeSelect TimeSelect Checkbox ColorInput DateInput TimeInput DateTimeLocalInput EmailInput PasswordInput RangeInput SearchInput TelephoneInput UrlInput FileInput),
          &{&1, "Surface.Components.Form.#{&1}"}
        )
        |> Map.merge(%{
          "Form" => "Surface.Components.Form",
          "Link" => "Surface.Components.Link",
          "Button" => "Surface.Components.Link.Button"
        }),
      context: :library
    }
  end
end
