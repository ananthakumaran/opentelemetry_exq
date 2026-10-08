defmodule OpentelemetryExq.EnqueueMiddleware do
  @moduledoc """
  Traces enqueue requests and propagates context through job metadata.

  Add this module to Exq's `:enqueue_middleware` list.
  """
  @behaviour Exq.Enqueue.Middleware

  alias OpenTelemetry.Span
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.{CodeAttributes, MessagingAttributes}
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
      MessagingAttributes.messaging_system() => "exq",
      MessagingAttributes.messaging_operation_name() => Atom.to_string(pipeline.operation),
      MessagingAttributes.messaging_operation_type() => "send"
    }

    attributes =
      case queues do
        [queue] -> Map.put(attributes, MessagingAttributes.messaging_destination_name(), queue)
        _ -> attributes
      end

    attributes =
      case pipeline.jobs do
        [{job, _options}] ->
          attributes
          |> Map.merge(body_attributes(job.args))
          |> Map.merge(%{
            CodeAttributes.code_namespace() => job.class,
            CodeAttributes.code_function() => "perform",
            MessagingAttributes.messaging_message_id() => job.jid,
            "messaging.exq.class" => job.class
          })

        jobs ->
          Map.put(attributes, MessagingAttributes.messaging_batch_message_count(), length(jobs))
      end

    Tracer.with_span name, kind: :producer, attributes: attributes do
      jobs =
        Enum.map(pipeline.jobs, fn {job, options} ->
          headers =
            case Map.get(job.meta, "trace_propagation_headers") do
              headers when is_map(headers) -> headers
              _ -> %{}
            end

          headers =
            :otel_propagator_text_map.inject(
              :opentelemetry.get_text_map_injector(),
              headers,
              fn key, value, carrier -> Map.put(carrier, key, value) end
            )

          meta = Map.put(job.meta, "trace_propagation_headers", headers)
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

  defp body_attributes(args) do
    case Exq.Support.Config.serializer().encode(args) do
      {:ok, encoded} ->
        %{MessagingAttributes.messaging_message_body_size() => IO.iodata_length(encoded)}

      _ ->
        %{}
    end
  rescue
    # Observability must not make otherwise valid custom/inline jobs fail.
    _ -> %{}
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

    Tracer.set_attribute(ErrorAttributes.error_type(), type)
    Tracer.set_status(:error, "")
  end
end
