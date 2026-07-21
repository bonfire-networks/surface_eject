defmodule SurfaceEject.ExDefinitionsTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Ex, Profile}
  alias SurfaceEject.Profiles

  @generic %Context{profile: %Profile{declarations: :attr}}
  @compat %Context{profile: %Profile{declarations: :compat}}

  defp convert(source, ctx) do
    {out, _logs} = Ex.convert(source, ctx)
    out
  end

  defp convert_logs(source, ctx) do
    {_out, logs} = Ex.convert(source, ctx)
    logs
  end

  describe "generic :attr mode" do
    test "prop becomes attr (declarations adjacent to a 1-arity def)" do
      source = """
      defmodule A do
        prop name, :string, required: true
        prop color, :string, default: "blue"

        def render(assigns) do
          nil
        end
      end
      """

      out = convert(source, @generic)
      assert out =~ ~s(attr :name, :string, required: true)
      assert out =~ ~s(attr :color, :string, default: "blue")
      refute out =~ "prop "
    end

    test "type mappings: event/css_class/fun/generator" do
      source = """
      defmodule A do
        prop click, :event
        prop classes, :css_class
        prop cb, :fun
        prop gen, :generator

        def render(assigns), do: nil
      end
      """

      out = convert(source, @generic)
      assert out =~ ~s(attr :click, :string)
      assert out =~ ~s(attr :classes, :any)
      assert out =~ ~s(attr :cb, :any)
      assert out =~ ~s(attr :gen, :list)

      logs = convert_logs(source, @generic)
      assert Enum.any?(logs, &(&1.category == :event_prop))
      assert Enum.any?(logs, &(&1.category == :fun_prop))
    end

    test "slot declarations" do
      source = """
      defmodule A do
        slot default, required: true
        slot header
        slot col, arg: [item: :any]

        def render(assigns), do: nil
      end
      """

      out = convert(source, @generic)
      assert out =~ ~s(slot :inner_block, required: true)
      assert out =~ ~s(slot :header)
      assert out =~ ~s(slot :col)
      refute out =~ "arg:"
      assert Enum.any?(convert_logs(source, @generic), &(&1.category == :slot_arg))
    end

    test "declarations NOT adjacent to a 1-arity def are left and flagged" do
      source = """
      defmodule A do
        prop name, :string

        def not_a_component(a, b), do: {a, b}
      end
      """

      out = convert(source, @generic)
      assert out =~ "prop name, :string"
      refute out =~ "attr :name"

      assert Enum.any?(
               convert_logs(source, @generic),
               &(&1.category == :attr_adjacency and &1.severity == :manual_required)
             )
    end

    test "data declarations are left and flagged in generic mode" do
      source = """
      defmodule A do
        data count, :integer, default: 0

        def render(assigns), do: nil
      end
      """

      assert convert(source, @generic) =~ "data count, :integer"
      assert Enum.any?(convert_logs(source, @generic), &(&1.category == :data_decl))
    end
  end

  describe ":compat mode (Bonfire)" do
    test "prop/data/slot left completely untouched" do
      source = """
      defmodule A do
        prop name, :string, required: true
        data count, :integer, default: 0
        slot default

        def render(assigns), do: nil
      end
      """

      assert convert(source, @compat) == source
    end

    test "sigils still convert in compat mode" do
      source = ~s|defmodule A do\n  def render(assigns), do: ~F"{!-- c --}"\nend\n|
      assert convert(source, @compat) =~ ~S(~H"<%!-- c --%>")
    end

    test "use-atom swap: Surface web-macro atoms → plain context-lib-wired atoms" do
      source = "defmodule A do\n  use My.Web, :stateless_component\nend\n"
      bonfire = %Context{profile: Profiles.Bonfire.profile()}

      out = convert(source, bonfire)
      assert out =~ "use My.Web, :function_component"
      refute out =~ ":stateless_component"
      assert Enum.any?(convert_logs(source, bonfire), &(&1.category == :use_atom))
    end

    test "use-atom swap: surface_live_view_child → live_view_child (nested-LV plain analogue)" do
      source = "defmodule A do\n  use My.Web, :surface_live_view_child\nend\n"
      bonfire = %Context{profile: Profiles.Bonfire.profile()}

      assert convert(source, bonfire) =~ "use My.Web, :live_view_child"
    end
  end

  describe ":native declarations (attr where possible, live_attr elsewhere)" do
    defp native_ctx(module, kind, extra \\ []) do
      profile = %{
        Profiles.Bonfire.profile()
        | declarations: :native,
          live_attr: Keyword.get(extra, :live_attr, true),
          embedded_render_delegate: "render_template"
      }

      %Context{profile: profile, module: module, type_map: %{module => kind}}
    end

    test "sface-colocated function component: native attr/slot + delegating render; data → live_attr" do
      source = """
      defmodule My.CardLive do
        use My.Web, :stateless_component

        prop label, :string, default: "hi"
        prop klass, :css_class

        slot default

        data computed, :any, default: nil
      end
      """

      out = convert(source, native_ctx("My.CardLive", :function_component))

      assert out =~ ~s|attr :label, :string, default: "hi"|
      assert out =~ "attr :klass, :any"
      assert out =~ "slot :inner_block"
      # data stays out of the public attr API, original type kept
      assert out =~ "live_attr :computed, :any, default: nil"
      # the def the attrs bind to (before web.ex's embed hook runs)
      assert out =~ "def render(assigns), do: render_template(assigns)"
      refute out =~ "prop "
    end

    test "inline-render function component: attr adjacency as before, NO delegate emitted" do
      source = """
      defmodule My.Inline do
        use Surface.Component

        prop a, :string

        def render(assigns), do: nil
      end
      """

      out = convert(source, native_ctx("My.Inline", :function_component))

      assert out =~ "attr :a, :string"
      refute out =~ "render_template"
    end

    test "live component: prop → live_attr (reapply), data → internal, slot deleted" do
      source = """
      defmodule My.Modal do
        use My.Web, :stateful_component

        prop title, :string, default: "t", required: false

        data expanded, :boolean, default: false

        slot side

        def update(assigns, socket), do: {:ok, socket}
      end
      """

      out = convert(source, native_ctx("My.Modal", :live_component))

      assert out =~ ~s|live_attr :title, :string, default: "t", required: false|
      assert out =~ "live_attr :expanded, :boolean, default: false, internal: true"
      refute out =~ "slot side"
      refute out =~ "prop "
      refute out =~ ~r/^\s*data /m
    end

    test "live view: data → live_attr, prop deleted" do
      source = """
      defmodule My.View do
        use My.Web, :surface_live_view

        prop ignored, :any

        data page_title, :string, default: "home"
      end
      """

      out = convert(source, native_ctx("My.View", :live_view))

      assert out =~ ~s|live_attr :page_title, :string, default: "home"|
      refute out =~ "prop ignored"
    end

    test "helper defs (any arity) don't suppress the delegate — attrs must bind render/1" do
      source = """
      defmodule My.CardLive do
        use My.Web, :stateless_component

        prop label, :string, default: "hi"

        def smart_input_module, do: [:article]

        defp helper(x), do: x
      end
      """

      out = convert(source, native_ctx("My.CardLive", :function_component))

      # delegate right after the declarations, BEFORE the helpers
      assert out =~
               ~r/attr :label.*?\n\s*def render\(assigns\), do: render_template\(assigns\)\s*\n\s*def smart_input_module/s
    end

    test "profile call_renames: render_sface() calls become render_template()" do
      source = """
      defmodule My.CardLive do
        use My.Web, :stateless_component

        prop label, :string, default: "hi"

        def render(assigns) do
          assigns
          |> assign(:x, 1)
          |> render_sface()
        end
      end
      """

      out = convert(source, native_ctx("My.CardLive", :function_component))

      assert out =~ "|> render_template()"
      refute out =~ "render_sface"
    end

    test "non-adjacent fn-comp props (macro between decls and render) fall back to live_attr" do
      source = """
      defmodule My.NavLive do
        use My.Web, :stateless_component

        prop page, :string, default: nil

        declare_nav_component("Links")

        def render(assigns), do: nil
      end
      """

      out = convert(source, native_ctx("My.NavLive", :function_component))

      # attr would bind declare_nav_component's generated def — live_attr
      # is position-independent
      assert out =~ "live_attr :page, :string, default: nil"
      # \b: a bare "attr :page" (live_attr contains the substring)
      refute out =~ ~r/\battr :page/
      refute out =~ "render_template"
    end

    test "attr default conflicting with the declared type falls back to :any (Surface never validated)" do
      source = """
      defmodule My.Inline do
        use Surface.Component

        prop modal_id, :string, default: :sidebar_composer

        def render(assigns), do: nil
      end
      """

      ctx = native_ctx("My.Inline", :function_component)
      out = convert(source, ctx)

      assert out =~ "attr :modal_id, :any, default: :sidebar_composer"

      assert Enum.any?(
               convert_logs(source, ctx),
               &(&1.category == :attr_type_conflict and &1.severity == :warning)
             )
    end

    test "live_attr: false emits the translation COMMENTED (file still compiles)" do
      source = """
      defmodule My.Modal do
        use Surface.LiveComponent

        prop title, :string, default: "t"
      end
      """

      out = convert(source, native_ctx("My.Modal", :live_component, live_attr: false))

      assert out =~ ~s|# live_attr :title, :string, default: "t"|
      refute out =~ ~r/^\s*prop /m

      assert Enum.any?(
               convert_logs(source, native_ctx("My.Modal", :live_component, live_attr: false)),
               &(&1.severity == :manual_required and &1.category == :live_attr_commented)
             )
    end
  end
end
