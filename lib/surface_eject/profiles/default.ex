defmodule SurfaceEject.Profiles.Default do
  @moduledoc """
  The default profile, matching a stock `mix surface.init` project: generic `:attr` declarations, the one web-macro atom the installer patches into the web module (`use MyAppWeb, :surface_live_view`), and Surface's own component library as known aliases (generic to every Surface project).
  """

  alias SurfaceEject.Profile

  def profile do
    %Profile{
      declarations: :attr,
      web_module: :rewrite,
      remote_call: :render,
      # `mix surface.init` appends a `surface_live_view` def to the web
      # module; the plain phx.new counterpart is :live_view
      web_macros: %{surface_live_view: :live_view},
      use_atom_map: %{surface_live_view: :live_view},
      aliases: builtin_aliases(),
      builtin_components: builtin_components_core()
    }
  end

  @doc """
  Form mappings onto phx.new-style core components: `<Form>` → `<.form>`, standalone input controls → `<.input type=...>`, `<Label>` → `<.label>`. Cluster components (`Field`, `ErrorTag`, `Inputs`, …) are deliberately absent as they communicate via Surface context and need the structural collapse (Tier 2), so they stay flagged.
  """
  def builtin_components_core do
    inputs = %{
      "TextInput" => "text",
      "TextArea" => "textarea",
      "NumberInput" => "number",
      "EmailInput" => "email",
      "PasswordInput" => "password",
      "HiddenInput" => "hidden",
      "Checkbox" => "checkbox",
      "RadioButton" => "radio",
      "Select" => "select",
      "DateInput" => "date",
      "TimeInput" => "time",
      "DateTimeLocalInput" => "datetime-local",
      "ColorInput" => "color",
      "RangeInput" => "range",
      "SearchInput" => "search",
      "TelephoneInput" => "tel",
      "UrlInput" => "url",
      "FileInput" => "file"
    }

    Map.new(inputs, fn {name, type} -> {"Surface.Components.Form.#{name}", {:input, type}} end)
    |> Map.merge(%{
      "Surface.Components.Form" => :form,
      "Surface.Components.Form.Label" => {:rename, "label"},
      # plain :get links only, method/label/event props flag instead
      "Surface.Components.Link" => :link
    })
  end

  @doc """
  Surface's own component library (`Surface.Components.*`) keyed by the aliases projects conventionally use — lets call-site resolution flag them as `:surface_builtin` even when the file doesn't alias them explicitly.
  """
  def builtin_aliases do
    Map.new(
      ~w(Field FieldContext Label ErrorTag Inputs HiddenInput HiddenInputs TextInput TextArea NumberInput RadioButton Select MultipleSelect OptionsForSelect DateTimeSelect TimeSelect Checkbox ColorInput DateInput TimeInput DateTimeLocalInput EmailInput PasswordInput RangeInput SearchInput TelephoneInput UrlInput FileInput),
      &{&1, "Surface.Components.Form.#{&1}"}
    )
    |> Map.merge(%{
      "Form" => "Surface.Components.Form",
      "Link" => "Surface.Components.Link",
      "Button" => "Surface.Components.Link.Button"
    })
  end
end