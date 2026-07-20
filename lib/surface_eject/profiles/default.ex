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
      aliases: builtin_aliases()
    }
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