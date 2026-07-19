defmodule SurfaceEject.Test.Stubs.Card do
  @moduledoc false
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <span>card:{@a}</span>
    """
  end
end

defmodule SurfaceEject.Test.Stubs.LC do
  @moduledoc false
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"""
    <div>lc</div>
    """
  end
end
