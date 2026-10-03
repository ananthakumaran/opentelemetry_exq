defmodule OpentelemetryExq.Middleware do
  @moduledoc """
  Traces job execution and attaches the job's context inside the worker Task.

  Add this module to Exq's worker middleware after `Exq.Middleware.Job`.
  """
  @behaviour Exq.Middleware.Behaviour

  alias Exq.Middleware.Pipeline
  alias OpenTelemetry.{Ctx, Span}
  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def before_work(pipeline) do
    relationship = Application.get_env(:opentelemetry_exq, :span_relationship, :link)

    unless relationship in [:link, :child, :none] do
      raise ArgumentError, "span_relationship must be :link, :child, or :none"
    end

    job = pipeline.assigns.job
    carrier = Enum.filter(job.meta, fn {_key, value} -> is_binary(value) end)
    ctx = :otel_propagator_text_map.extract_to(%{}, carrier)
    parent = Tracer.current_span_ctx(ctx)

    links =
      if relationship == :link and Span.is_valid(parent),
        do: [OpenTelemetry.link(parent)],
        else: []

    ctx = if relationship == :child, do: ctx, else: Tracer.set_current_span(ctx, :undefined)
    enqueued_at = DateTime.from_unix!(round(job.enqueued_at * 1000), :millisecond)

    attributes = %{
      "messaging.system" => "exq",
      "messaging.destination.name" => job.queue,
      "messaging.operation.name" => "process",
      "messaging.operation.type" => "process",
      "messaging.message.id" => job.jid,
      "messaging.exq.class" => job.class,
      "messaging.exq.retry_count" => job.retry_count || 0,
      "messaging.exq.enqueued_at" => DateTime.to_iso8601(enqueued_at)
    }

    span =
      Tracer.start_span(ctx, "process #{job.queue}",
        kind: :consumer,
        links: links,
        attributes: attributes
      )

    ctx = Tracer.set_current_span(ctx, span)
    token = Ctx.attach(ctx)

    pipeline
    |> Pipeline.assign(:otel_span, span)
    |> Pipeline.assign(:otel_context, ctx)
    |> Pipeline.assign(:otel_token, token)
  end

  @impl true
  def around_perform(pipeline, next) do
    token = Ctx.attach(pipeline.assigns.otel_context)

    try do
      next.(pipeline)
    after
      Ctx.detach(token)
    end
  end

  @impl true
  def after_processed_work(pipeline) do
    Span.end_span(pipeline.assigns.otel_span)
    Ctx.detach(pipeline.assigns.otel_token)
    pipeline
  end

  @impl true
  def after_failed_work(pipeline) do
    {reason, stacktrace} = exception(pipeline.assigns.error)
    span = pipeline.assigns.otel_span
    Span.record_exception(span, reason, stacktrace)

    type =
      case reason do
        %{__exception__: true, __struct__: module} -> to_string(module)
        _ -> "_OTHER"
      end

    Span.set_attribute(span, "error.type", type)
    Span.set_status(span, OpenTelemetry.status(:error, ""))
    after_processed_work(pipeline)
  end

  defp exception({reason, [entry | _] = stacktrace})
       when is_tuple(entry) and tuple_size(entry) in [3, 4],
       do: {reason, stacktrace}

  defp exception(reason), do: {reason, []}
end
