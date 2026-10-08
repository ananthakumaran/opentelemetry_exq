defmodule OpentelemetryExq do
  @moduledoc """
  OpenTelemetry tracing for Exq jobs.

  Add `OpentelemetryExq.Middleware` to Exq's worker middleware, and
  `OpentelemetryExq.EnqueueMiddleware` to its enqueue middleware.

  Configure the relationship between job spans and propagated enqueue spans with
  `config :opentelemetry_exq, span_relationship: :link`. The default, `:link`,
  starts a new trace with a link; `:child` continues the trace as a child;
  `:none` starts a new trace without a link.
  """
end
