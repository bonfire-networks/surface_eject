defmodule SurfaceEject.CallSitesTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Template}
  alias SurfaceEject.Profiles

  @ctx %Context{
    profile: Profiles.Bonfire.profile(),
    type_map: %{
      "Some.Card" => :function_component,
      "Some.Live" => :live_component
    },
    aliases: %{"Card" => "Some.Card", "LiveThing" => "Some.Live"}
  }

  defp convert(source, ctx \\ @ctx) do
    {out, _logs} = Template.convert(source, ctx)
    out
  end

  defp convert_logs(source, ctx \\ @ctx) do
    {_out, logs} = Template.convert(source, ctx)
    logs
  end

  describe "function components (remote_call :render)" do
    test "aliased, self-closing" do
      assert convert(~S(<Card a={@x} />)) == ~S(<Card.render a={@x} />)
    end

    test "dotted tag with a lowercase final segment is already-valid HEEx — skipped" do
      for src <- [
            ~S(<Iconify.iconify icon="ph:x" class="w-4" />),
            ~S(<Phoenix.Component.live_file_input upload={@u} />)
          ] do
        assert convert(src) == src
        refute Enum.any?(convert_logs(src), &(&1.category == :unknown_component))
      end
    end

    test "web-macro-provided component aliases resolve via the profile" do
      ctx = %{
        @ctx
        | type_map: %{
            "Bonfire.UI.Common.LinkLive" => :function_component,
            "Bonfire.UI.Common.DropdownLive" => :function_component
          }
      }

      assert convert(~S(<LinkLive to="/x">y</LinkLive>), ctx) ==
               ~S(<LinkLive.render to="/x">y</LinkLive.render>)

      assert convert(~S(<Dropdown />), ctx) == ~S(<Dropdown.render />)
    end

    test "aliased, with children (close tag renamed too)" do
      assert convert("<Card>x</Card>") == "<Card.render>x</Card.render>"
    end

    test "full module name" do
      assert convert("<Some.Card />") == "<Some.Card.render />"
    end
  end

  describe "live components" do
    test "self-closing becomes <.live_component module=...>" do
      assert convert(~S(<LiveThing id="x" />)) ==
               ~S(<.live_component module={Some.Live} id="x" />)
    end

    test "with plain children (inner_block passes through)" do
      assert convert(~S(<LiveThing id="x">c</LiveThing>)) ==
               ~S(<.live_component module={Some.Live} id="x">c</.live_component>)
    end

    test "with slot entries + a profile entry point renames to the function component" do
      # the entry point (a function component on the live component's module, forwarding assigns incl. slots into <.live_component>) accepts slot entries natively
      ctx = %{
        @ctx
        | profile: %{
            @ctx.profile
            | live_component_slot_entrypoints: %{"Some.Live" => "open_thing"}
          }
      }

      src = ~S(<LiveThing id="x"><:item>y</:item></LiveThing>)

      assert convert(src, ctx) ==
               ~S(<LiveThing.open_thing id="x"><:item>y</:item></LiveThing.open_thing>)

      refute Enum.any?(convert_logs(src, ctx), &(&1.severity == :manual_required))
    end

    test "with slot entries is left unchanged and flagged" do
      src = ~S(<LiveThing id="x"><:item>y</:item></LiveThing>)
      assert convert(src) == src

      assert Enum.any?(
               convert_logs(src),
               &(&1.category == :live_component_slots and &1.severity == :manual_required)
             )
    end
  end

  describe "dynamic dispatch (profile suffix rules)" do
    test "StatelessComponent/StatefulComponent get .render suffix" do
      assert convert(~S|<StatelessComponent module={maybe_component(M, @__context__)} />|) ==
               ~S|<StatelessComponent.render module={maybe_component(M, @__context__)} />|

      assert convert("<StatefulComponent id=\"i\" module={M}>x</StatefulComponent>") ==
               "<StatefulComponent.render id=\"i\" module={M}>x</StatefulComponent.render>"
    end
  end

  describe "Surface built-ins" do
    test "flagged :manual_required and left unchanged (aliased via web-macro aliases)" do
      # Field has no builtin_components mapping (cluster component), exercises the flag path; mapped builtins like TextInput now convert
      ctx = %{
        @ctx
        | aliases: Map.put(@ctx.aliases, "Field", "Surface.Components.Form.Field")
      }

      src = ~S(<Field name={:name} />)
      assert convert(src, ctx) == src

      assert Enum.any?(
               convert_logs(src, ctx),
               &(&1.category == :surface_builtin and &1.severity == :manual_required)
             )
    end
  end

  describe "unknown components" do
    test "left unchanged with info log (M1 behavior preserved)" do
      src = ~S(<Mystery.Thing />)
      assert convert(src) == src
      assert Enum.any?(convert_logs(src), &(&1.category == :unknown_component))
    end
  end
end
