defmodule SurfaceEject.LogEntry do
  @moduledoc """
  A structured record of one decision, transform, or flag made during
  conversion. All entries end up in the final report, grouped by severity
  and category.
  """

  defstruct phase: :template,
            severity: :info,
            file: nil,
            line: nil,
            message: nil,
            category: nil

  @type t :: %__MODULE__{
          phase: atom(),
          severity: :info | :warning | :manual_required,
          file: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t() | nil,
          category: atom()
        }
end
