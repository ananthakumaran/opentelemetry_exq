defmodule OpentelemetryExq.JobHandler do
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

  # https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/messaging.md
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
      "messaging.system": :exq,
      "messaging.destination": queue,
      "messaging.destination_kind": :queue,
      "messaging.operation": :process,
      "messaging.exq.jid": jid,
      "messaging.exq.class": class,
      "messaging.exq.retry_count": retry_count,
      "messaging.exq.enqueued_at": DateTime.to_iso8601(enqueued_at)
    }

    span_name = "#{class} process"

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
    Span.set_status(ctx, OpenTelemetry.status(:error, ""))

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end
end
