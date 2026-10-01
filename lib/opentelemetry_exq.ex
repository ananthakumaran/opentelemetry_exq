defmodule OpentelemetryExq do
  @moduledoc """
  OpenTelemetry tracing for Exq jobs.

  Enable `Exq.Middleware.Telemetry` in your Exq middleware configuration and call
  `setup/0` once during application startup.
  """

  @doc """
  Attaches tracing handlers to Exq's job start, stop, and exception events.

  Options are currently unused.
  """
  @spec setup(Keyword.t()) :: :ok
  def setup(_opts \\ []) do
    OpentelemetryExq.JobHandler.attach()

    :ok
  end
end
