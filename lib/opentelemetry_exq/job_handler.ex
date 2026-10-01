defmodule OpentelemetryExq.JobHandler do
  @moduledoc false

  alias OpenTelemetry.Span

  @tracer_id __MODULE__

  def attach() do
    attach_job_start_handler()
    attach_job_stop_handler()
    attach_job_exception_handler()
  end

  defp attach_job_start_handler() do
    :telemetry.attach(
      "#{__MODULE__}.job_start",
      [:exq, :job, :start],
      &__MODULE__.handle_job_start/4,
      []
    )
  end

  defp attach_job_stop_handler() do
    :telemetry.attach(
      "#{__MODULE__}.job_stop",
      [:exq, :job, :stop],
      &__MODULE__.handle_job_stop/4,
      []
    )
  end

  defp attach_job_exception_handler() do
    :telemetry.attach(
      "#{__MODULE__}.job_exception",
      [:exq, :job, :exception],
      &__MODULE__.handle_job_exception/4,
      []
    )
  end

  # https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/
  def handle_job_start(_event, _measurements, metadata, _config) do
    %{
      class: class,
      enqueued_at: enqueued_at,
      jid: jid,
      queue: queue,
      retry_count: retry_count
    } = metadata

    parent = OpenTelemetry.Tracer.current_span_ctx()
    links = if parent == :undefined, do: [], else: [OpenTelemetry.link(parent)]
    OpenTelemetry.Tracer.set_current_span(:undefined)

    attributes = %{
      "messaging.system" => "exq",
      "messaging.destination.name" => queue,
      "messaging.operation.name" => "process",
      "messaging.operation.type" => "process",
      "messaging.message.id" => jid,
      "messaging.exq.class" => class,
      "messaging.exq.retry_count" => retry_count,
      "messaging.exq.enqueued_at" => DateTime.to_iso8601(enqueued_at)
    }

    span_name = "process #{queue}"

    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, span_name, metadata, %{
      kind: :consumer,
      links: links,
      attributes: attributes
    })
  end

  def handle_job_stop(_event, _measurements, metadata, _config) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  def handle_job_exception(
        _event,
        _measurements,
        %{stacktrace: stacktrace, reason: reason} = metadata,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    # Record exception and mark the span as errored
    Span.record_exception(ctx, reason, stacktrace)

    error_type =
      case reason do
        %{__exception__: true, __struct__: module} -> to_string(module)
        _ -> "_OTHER"
      end

    Span.set_attribute(ctx, "error.type", error_type)
    Span.set_status(ctx, OpenTelemetry.status(:error, ""))

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end
end
