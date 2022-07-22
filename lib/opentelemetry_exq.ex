defmodule OpentelemetryExq do
  @spec setup(Keyword.t()) :: :ok
  def setup(_opts \\ []) do
    OpentelemetryExq.JobHandler.attach()

    :ok
  end
end
