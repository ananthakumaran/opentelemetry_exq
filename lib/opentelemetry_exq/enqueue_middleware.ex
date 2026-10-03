defmodule OpentelemetryExq.EnqueueMiddleware do
  @moduledoc """
  Traces enqueue requests and propagates context through job metadata.

  Add this module to Exq's `:enqueue_middleware` list.
  """
  @behaviour Exq.Enqueue.Middleware

  alias OpenTelemetry.Span
  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def around_enqueue(%{jobs: []} = pipeline, next), do: next.(pipeline)

  def around_enqueue(pipeline, next) do
    queues = pipeline.jobs |> Enum.map(fn {job, _options} -> job.queue end) |> Enum.uniq()

    name =
      case queues do
        [queue] -> "send #{queue}"
        _ -> "send"
      end

    attributes = %{
      "messaging.system" => "exq",
      "messaging.operation.name" => Atom.to_string(pipeline.operation),
      "messaging.operation.type" => "send"
    }

    attributes =
      case queues do
        [queue] -> Map.put(attributes, "messaging.destination.name", queue)
        _ -> attributes
      end

    attributes =
      case pipeline.jobs do
        [{job, _options}] ->
          Map.merge(attributes, %{
            "messaging.message.id" => job.jid,
            "messaging.exq.class" => job.class
          })

        jobs ->
          Map.put(attributes, "messaging.batch.message_count", length(jobs))
      end

    Tracer.with_span name, kind: :producer, attributes: attributes do
      jobs =
        Enum.map(pipeline.jobs, fn {job, options} ->
          meta =
            :otel_propagator_text_map.inject(
              :opentelemetry.get_text_map_injector(),
              job.meta,
              fn key, value, carrier -> Map.put(carrier, key, value) end
            )

          {%{job | meta: meta}, options}
        end)

      try do
        result = next.(%{pipeline | jobs: jobs})
        record_result(result, pipeline.operation)
        result
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          Span.record_exception(Tracer.current_span_ctx(), reason, stacktrace)
          record_error(reason)
          :erlang.raise(kind, reason, stacktrace)
      end
    end
  end

  defp record_result({:ok, results}, :enqueue_all) when is_list(results) do
    Enum.each(results, &record_result(&1, :enqueue))
    statuses = results |> Enum.map(fn {status, _} -> Atom.to_string(status) end) |> Enum.uniq()

    outcome =
      case statuses do
        [status] -> status
        _ -> "mixed"
      end

    Tracer.set_attribute("messaging.exq.enqueue_result", outcome)
  end

  defp record_result({status, value}, _operation) do
    Tracer.set_attribute("messaging.exq.enqueue_result", Atom.to_string(status))
    if status == :error, do: record_error(value)
  end

  defp record_error(reason) do
    type =
      case reason do
        %{__exception__: true, __struct__: module} -> to_string(module)
        _ -> "_OTHER"
      end

    Tracer.set_attribute("error.type", type)
    Tracer.set_status(:error, "")
  end
end
