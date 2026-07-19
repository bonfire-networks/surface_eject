defmodule SurfaceEject.ExDefinitionsTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Ex, Profile}

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
      bonfire = %Context{profile: SurfaceEject.Profile.bonfire()}

      out = convert(source, bonfire)
      assert out =~ "use My.Web, :function_component"
      refute out =~ ":stateless_component"
      assert Enum.any?(convert_logs(source, bonfire), &(&1.category == :use_atom))
    end
  end
end
