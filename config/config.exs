import Config

if Mix.env() == :test do
  config :logger, level: :warning

  config :exq,
    start_on_application: false,
    url: System.get_env("EXQ_REDIS_URL") || "redis://127.0.0.1:6379/0",
    backoff: OpentelemetryExq.MiddlewareTest.ImmediateBackoff,
    enqueue_middleware: [OpentelemetryExq.EnqueueMiddleware],
    middleware: [
      Exq.Middleware.Stats,
      Exq.Middleware.Job,
      Exq.Middleware.Manager,
      Exq.Middleware.Logger,
      OpentelemetryExq.Middleware
    ]

  config :opentelemetry,
    traces_exporter: :none,
    processors: [{:otel_simple_processor, %{}}]
end
