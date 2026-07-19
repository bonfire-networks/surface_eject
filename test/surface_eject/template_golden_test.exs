defmodule SurfaceEject.TemplateGoldenTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Template}

  @fixtures Path.expand("../fixtures", __DIR__)

  for name <- ~w(flags membership load_more) do
    test "golden: #{name}" do
      dir = Path.join(unquote(@fixtures), unquote(name))
      [input_path] = Path.wildcard(Path.join(dir, "input/*"))
      [expected_path] = Path.wildcard(Path.join(dir, "expected/*"))

      {output, _logs} =
        input_path
        |> File.read!()
        |> Template.convert(%Context{file: input_path})

      expected = File.read!(expected_path)

      if output != expected do
        # byte-exact diff aid
        flunk("""
        golden mismatch for #{unquote(name)}

        --- expected ---
        #{expected}
        --- got ---
        #{output}
        """)
      end
    end
  end
end
