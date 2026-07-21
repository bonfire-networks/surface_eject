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

    test "with slot entries converts directly to <.live_component> (LV delivers named slots as assigns)" do
      # verified at runtime: <.live_component module={M}><:item> delivers @item
      # to the component, so no entry-point indirection is needed
      src = ~S(<LiveThing id="x"><:item>y</:item></LiveThing>)

      assert convert(src) ==
               ~S(<.live_component module={Some.Live} id="x"><:item>y</:item></.live_component>)

      refute Enum.any?(convert_logs(src), &(&1.severity == :manual_required))
      # still logged (info) so reviewers can see which callers pass slots
      assert Enum.any?(
               convert_logs(src),
               &(&1.category == :live_component_slots and &1.severity == :info)
             )
    end
  end

  describe "live views as tags (Surface's live_render sugar)" do
    test "self-closing LiveView tag becomes live_render" do
      ctx = %{@ctx | type_map: %{"My.StickyLive" => :live_view}}

      src = ~S|<My.StickyLive id={:persistent} sticky container={{:div, class: "w"}} />|

      assert convert(src, ctx) ==
               ~S|{live_render(@socket, My.StickyLive, id: :persistent, sticky: true, container: {:div, class: "w"})}|
    end
  end

  describe "dynamic dispatch (profile rules)" do
    test "StatelessComponent → <.dynamic_component> (module stays an attr)" do
      assert convert(~S|<StatelessComponent module={maybe_component(M, @__context__)} />|) ==
               ~S|<.dynamic_component module={maybe_component(M, @__context__)} />|
    end

    test "StatelessComponent with slots renames open + close" do
      assert convert("<StatelessComponent module={M}>x</StatelessComponent>") ==
               "<.dynamic_component module={M}>x</.dynamic_component>"
    end

    test "StatefulComponent → <.live_component> (dynamic module kept, no injection)" do
      assert convert("<StatefulComponent id=\"i\" module={M}>x</StatefulComponent>") ==
               "<.live_component id=\"i\" module={M}>x</.live_component>"
    end

    test "StatefulComponent self-closing" do
      assert convert(~S|<StatefulComponent id="b" module={maybe_component(M, @c)} />|) ==
               ~S|<.live_component id="b" module={maybe_component(M, @c)} />|
    end

    test "StatefulComponent WITH slot entries still converts (dynamic: no entrypoint possible; <.live_component> forwards slots)" do
      src = ~S|<StatefulComponent id="f" module={M}><:bottom>x</:bottom></StatefulComponent>|
      out = convert(src)

      assert out == ~S|<.live_component id="f" module={M}><:bottom>x</:bottom></.live_component>|
      refute Enum.any?(convert_logs(src), &(&1.severity == :manual_required))
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
