defmodule OpentelemetryExq.PropagationTest do
  use ExUnit.Case, async: false
  require Record
  require OpenTelemetry.Tracer, as: Tracer

  @moduletag capture_log: true

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))
  Record.defrecordp(:link, Record.extract(:link, from_lib: "opentelemetry/include/otel_span.hrl"))

  defmodule Worker do
    require OpenTelemetry.Tracer, as: Tracer

    def perform(mode) do
      send(
        OpentelemetryExq.PropagationTest.Receiver,
        {:worker_context, Exq.worker_job(OpentelemetryExq.PropagationTest).meta,
         OpenTelemetry.Baggage.get_all()}
      )

      Tracer.with_span "worker child" do
        case mode do
          "enqueue" ->
            Exq.enqueue(OpentelemetryExq.PropagationTest, "mailers", __MODULE__, ["nested"])

          "error" ->
            raise "nested failure"

          "retry" ->
            attempt = Agent.get_and_update(__MODULE__, fn count -> {count, count + 1} end)
            if attempt == 0, do: raise("retry once"), else: :ok

          _ ->
            :ok
        end
      end
    end
  end

  defmodule InlineWorker do
    def perform(value) do
      send(self(), {:inline_result, value})
      value
    end
  end

  defmodule RaisingSerializer do
    def encode(_args), do: raise("serializer unavailable")
  end

  defmodule Reject do
    @behaviour Exq.Enqueue.Middleware
    def around_enqueue(_pipeline, _next), do: {:error, :blocked}
  end

  setup context do
    :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    OpenTelemetry.Ctx.clear()
    Process.register(self(), __MODULE__.Receiver)
    relationship = Application.get_env(:opentelemetry_exq, :span_relationship, :link)

    Application.put_env(
      :opentelemetry_exq,
      :span_relationship,
      Map.get(context, :relationship, :link)
    )

    previous = Application.fetch_env!(:exq, :enqueue_middleware)
    Application.put_env(:exq, :enqueue_middleware, [OpentelemetryExq.EnqueueMiddleware])
    namespace = "opentelemetry_exq_propagation:#{UUID.uuid4()}"
    url = Application.fetch_env!(:exq, :url)

    on_exit(fn ->
      Application.put_env(:opentelemetry_exq, :span_relationship, relationship)
      Application.put_env(:exq, :enqueue_middleware, previous)
      {:ok, redis} = Redix.start_link(url, sync_connect: true)
      {:ok, keys} = Redix.command(redis, ["KEYS", "#{namespace}:*"])
      if keys != [], do: Redix.command!(redis, ["DEL" | keys])
      GenServer.stop(redis)
    end)

    start_supervised!(
      {Exq,
       name: __MODULE__,
       namespace: namespace,
       queues: ["default", "mailers"],
       concurrency: 1,
       poll_timeout: 10,
       scheduler_poll_timeout: 10,
       redis_options: [sync_connect: true]}
    )

    {:ok, namespace: namespace}
  end

  test "links consumers to producer spans by default and preserves baggage and meta" do
    OpenTelemetry.Baggage.set(%{"tenant" => "tenant-1"})

    {:ok, jid} =
      Tracer.with_span "request" do
        enqueue("nested", meta: %{"tenant_id" => 42})
      end

    spans = receive_spans(4)
    request = named(spans, "request")
    producer = named(spans, "send default")
    job = named(spans, "process default")
    assert span(producer, :kind) == :producer
    assert span(producer, :parent_span_id) == span(request, :span_id)
    assert attributes(producer)["messaging.message.id"] == jid
    assert attributes(producer)["messaging.operation.type"] == "send"
    assert attributes(producer)["messaging.operation.name"] == "enqueue"

    for traced <- [producer, job] do
      assert attributes(traced)["code.namespace"] == "OpentelemetryExq.PropagationTest.Worker"
      assert attributes(traced)["code.function"] == "perform"

      assert attributes(traced)["messaging.message.body.size"] ==
               byte_size(Jason.encode!(["nested"]))

      refute Map.has_key?(attributes(traced), "messaging.message.conversation_id")
    end

    refute Map.has_key?(attributes(producer), "messaging.exq.queue_latency_ms")
    assert attributes(job)["messaging.exq.queue_latency_ms"] >= 0
    assert span(job, :parent_span_id) == :undefined
    refute span(job, :trace_id) == span(producer, :trace_id)
    assert_link(job, producer)
    assert_nested(job, spans)
    assert_receive {:worker_context, meta, baggage}
    assert meta["tenant_id"] == 42
    assert is_binary(meta["trace_propagation_headers"]["traceparent"])
    assert meta["trace_propagation_headers"]["baggage"] == "tenant=tenant-1"
    refute Map.has_key?(meta, "traceparent")
    refute Map.has_key?(meta, "tracestate")
    refute Map.has_key?(meta, "baggage")
    assert baggage["tenant"] == {"tenant-1", []}
    assert Tracer.current_span_ctx() == :undefined
  end

  @tag relationship: :child
  test "child relationship continues the producer trace" do
    {:ok, _} = Tracer.with_span("request", do: enqueue("nested"))
    spans = receive_spans(4)
    producer = named(spans, "send default")
    job = named(spans, "process default")
    assert span(job, :parent_span_id) == span(producer, :span_id)
    assert span(job, :trace_id) == span(producer, :trace_id)
    assert :otel_links.list(span(job, :links)) == []
    assert_nested(job, spans)
  end

  @tag relationship: :none
  test "none creates an unrelated job trace but still parents worker spans" do
    {:ok, _} = Tracer.with_span("request", do: enqueue("nested"))
    spans = receive_spans(4)
    producer = named(spans, "send default")
    job = named(spans, "process default")
    assert span(job, :parent_span_id) == :undefined
    assert :otel_links.list(span(job, :links)) == []
    refute span(job, :trace_id) == span(producer, :trace_id)
    assert_nested(job, spans)
  end

  @tag relationship: :child
  test "scheduled jobs retain producer context through Redis" do
    {first, second} =
      Tracer.with_span "request" do
        {:ok, first} =
          Exq.enqueue_at(__MODULE__, "default", DateTime.utc_now(), Worker, ["nested"])

        {:ok, second} = Exq.enqueue_in(__MODULE__, "mailers", 0, Worker, ["nested"])
        {first, second}
      end

    spans = receive_spans(7)

    for {jid, queue, operation} <- [
          {first, "default", "enqueue_at"},
          {second, "mailers", "enqueue_in"}
        ] do
      producer = named(spans, "send #{queue}")
      job = named(spans, "process #{queue}")
      assert attributes(producer)["messaging.message.id"] == jid
      assert attributes(producer)["messaging.operation.name"] == operation
      assert span(job, :parent_span_id) == span(producer, :span_id)
      assert span(job, :trace_id) == span(producer, :trace_id)
      assert_nested(job, spans)
    end
  end

  @tag relationship: :child
  test "bulk enqueue uses one producer span for immediate and scheduled jobs" do
    {:ok, results} =
      Tracer.with_span "request" do
        Exq.enqueue_all(__MODULE__, [
          ["default", Worker, ["nested"], []],
          ["mailers", Worker, ["nested"], [schedule: {:in, 0}]]
        ])
      end

    spans = receive_spans(6)
    producer = named(spans, "send")
    assert attributes(producer)["messaging.batch.message_count"] == 2
    assert attributes(producer)["messaging.operation.name"] == "enqueue_all"
    refute Map.has_key?(attributes(producer), "messaging.destination.name")
    refute Map.has_key?(attributes(producer), "code.namespace")
    refute Map.has_key?(attributes(producer), "code.function")
    refute Map.has_key?(attributes(producer), "messaging.message.body.size")

    for {:ok, jid} <- results do
      job = Enum.find(spans, &(attributes(&1)["messaging.message.id"] == jid))
      assert span(job, :parent_span_id) == span(producer, :span_id)
      assert span(job, :trace_id) == span(producer, :trace_id)
      assert_nested(job, spans)
    end
  end

  test "workers enqueue further jobs with their active span context automatically" do
    {:ok, _} = Tracer.with_span("request", do: enqueue("enqueue"))
    spans = receive_spans(7)
    first_job = named(spans, "process default")
    child = Enum.find(spans, &(span(&1, :parent_span_id) == span(first_job, :span_id)))
    producer = named(spans, "send mailers")
    assert span(producer, :parent_span_id) == span(child, :span_id)
    assert span(producer, :trace_id) == span(child, :trace_id)
    next_job = named(spans, "process mailers")
    assert_link(next_job, producer)
    assert_nested(next_job, spans)
  end

  test "retries retain the original producer context and get separate consumer spans" do
    start_supervised!(%{id: Worker, start: {Agent, :start_link, [fn -> 0 end, [name: Worker]]}})
    {:ok, jid} = Tracer.with_span("request", do: enqueue("retry", max_retries: 1))
    spans = receive_spans(6)
    producer = named(spans, "send default")
    jobs = Enum.filter(spans, &(span(&1, :name) == "process default"))
    assert length(jobs) == 2
    assert Enum.sort(Enum.map(jobs, &attributes(&1)["messaging.exq.retry_count"])) == [0, 1]
    assert length(Enum.uniq(Enum.map(jobs, &span(&1, :span_id)))) == 2

    for job <- jobs do
      assert attributes(job)["messaging.message.id"] == jid
      assert_link(job, producer)
      assert_nested(job, spans)
    end

    assert Agent.get(Worker, & &1) == 2
  end

  @tag relationship: :child
  test "nested worker failures retain their parent and report the job error" do
    {:ok, _} = Tracer.with_span("request", do: enqueue("error"))
    spans = receive_spans(4)
    job = named(spans, "process default")
    producer = named(spans, "send default")
    assert span(job, :parent_span_id) == span(producer, :span_id)
    assert attributes(job)["error.type"] == "Elixir.RuntimeError"
    assert span(job, :status) == OpenTelemetry.status(:error, "")
    assert_nested(job, spans)
  end

  test "missing and malformed propagation headers safely create root job spans" do
    Application.put_env(:exq, :enqueue_middleware, [])

    invalid_meta = [
      %{},
      %{"traceparent" => "invalid"},
      %{"traceparent" => 42, "tracestate" => %{}},
      %{"trace_propagation_headers" => %{"traceparent" => "invalid"}},
      %{"trace_propagation_headers" => %{"traceparent" => 42, "tracestate" => %{}}},
      %{"trace_propagation_headers" => nil},
      %{"trace_propagation_headers" => "invalid"},
      %{"trace_propagation_headers" => []}
    ]

    for meta <- invalid_meta do
      assert {:ok, _} = enqueue("nested", meta: meta)
    end

    spans = receive_spans(length(invalid_meta) * 2)
    jobs = Enum.filter(spans, &(span(&1, :name) == "process default"))
    assert length(jobs) == length(invalid_meta)

    for job <- jobs do
      assert span(job, :parent_span_id) == :undefined
      assert :otel_links.list(span(job, :links)) == []
      assert_nested(job, spans)
    end
  end

  @tag relationship: :child
  test "ignores top-level propagation fields" do
    Application.put_env(:exq, :enqueue_middleware, [])
    OpenTelemetry.Baggage.set(%{"tenant" => "top-level"})

    {:ok, _} =
      Tracer.with_span "external producer" do
        meta = :otel_propagator_text_map.inject([]) |> Map.new()
        enqueue("nested", meta: meta)
      end

    spans = receive_spans(3)
    producer = named(spans, "external producer")
    job = named(spans, "process default")
    assert span(job, :parent_span_id) == :undefined
    refute span(job, :trace_id) == span(producer, :trace_id)
    assert :otel_links.list(span(job, :links)) == []
    assert_receive {:worker_context, _meta, baggage}
    assert baggage == %{}
    assert_nested(job, spans)
  end

  @tag relationship: :child
  test "extracts nested headers without mixing in top-level headers" do
    Application.put_env(:exq, :enqueue_middleware, [])
    OpenTelemetry.Baggage.set(%{"tenant" => "nested"})

    {:ok, _} =
      Tracer.with_span "external producer" do
        headers = :otel_propagator_text_map.inject([]) |> Map.new()

        enqueue("nested",
          meta: %{
            "trace_propagation_headers" => headers,
            "traceparent" => "invalid",
            "baggage" => "tenant=top-level"
          }
        )
      end

    spans = receive_spans(3)
    producer = named(spans, "external producer")
    job = named(spans, "process default")
    assert span(job, :parent_span_id) == span(producer, :span_id)
    assert span(job, :trace_id) == span(producer, :trace_id)
    assert_receive {:worker_context, _meta, baggage}
    assert baggage["tenant"] == {"nested", []}
    assert_nested(job, spans)
  end

  test "serializes nested headers and preserves existing metadata", %{namespace: namespace} do
    meta = %{
      "tenant_id" => 42,
      "trace_propagation_headers" => %{"sentry-trace" => "existing", "traceparent" => "stale"}
    }

    assert {:ok, jid} = Exq.enqueue(__MODULE__, "staging", Worker, ["nested"], meta: meta)
    producer = named(receive_spans(1), "send staging")
    {:ok, redis} = Redix.start_link(Application.fetch_env!(:exq, :url), sync_connect: true)
    on_exit(fn -> if Process.alive?(redis), do: GenServer.stop(redis) end)

    [{:ok, {serialized, "staging"}}] =
      Exq.Redis.JobQueue.dequeue(redis, namespace, "host", ["staging"])

    payload = Jason.decode!(serialized)
    headers = payload["trace_propagation_headers"]
    assert payload["jid"] == jid
    assert payload["tenant_id"] == 42
    assert headers["sentry-trace"] == "existing"
    assert headers["traceparent"] != "stale"
    context = :otel_propagator_text_map.extract_to(%{}, Map.to_list(headers))
    parent = Tracer.current_span_ctx(context)
    assert OpenTelemetry.Span.trace_id(parent) == span(producer, :trace_id)
    assert OpenTelemetry.Span.span_id(parent) == span(producer, :span_id)
    refute Map.has_key?(payload, "traceparent")
    refute Map.has_key?(payload, "tracestate")
    refute Map.has_key?(payload, "baggage")
  end

  test "enqueue replaces malformed propagation header containers" do
    for headers <- [nil, "invalid", []] do
      assert {:ok, _} = enqueue("nested", meta: %{"trace_propagation_headers" => headers})
    end

    spans = receive_spans(9)
    assert Enum.count(spans, &(span(&1, :name) == "process default")) == 3

    for _ <- 1..3 do
      assert_receive {:worker_context, meta, _baggage}
      assert is_binary(meta["trace_propagation_headers"]["traceparent"])
      refute Map.has_key?(meta, "traceparent")
    end
  end

  test "records conflicts without marking the producer span as an error" do
    options = [unique_for: 60, unique_token: "conflict", meta: %{"tenant" => "1"}]
    assert {:ok, jid} = enqueue("nested", options)
    assert {:conflict, ^jid} = enqueue("nested", options)
    spans = receive_spans(4)
    producer = Enum.find(spans, &(attributes(&1)["messaging.exq.enqueue_result"] == "conflict"))
    assert span(producer, :kind) == :producer
    refute Map.has_key?(attributes(producer), "error.type")
  end

  test "bulk outcomes distinguish accepted and conflicting jobs" do
    options = [unique_for: 60, unique_token: "bulk-conflict"]

    assert {:ok, [{:ok, jid}, {:conflict, jid}]} =
             Exq.enqueue_all(__MODULE__, [
               ["default", Worker, ["nested"], options],
               ["default", Worker, ["nested"], options]
             ])

    spans = receive_spans(3)
    producer = named(spans, "send default")
    assert attributes(producer)["messaging.exq.enqueue_result"] == "mixed"
    assert attributes(producer)["messaging.batch.message_count"] == 2
  end

  test "deferred jobs retain context and their enqueue result", %{namespace: namespace} do
    options = [unique_for: 60, unique_until: :serial, unique_token: "deferred"]
    assert {:ok, first} = Exq.enqueue(__MODULE__, "staging", Worker, ["nested"], options)
    {:ok, redis} = Redix.start_link(Application.fetch_env!(:exq, :url), sync_connect: true)
    on_exit(fn -> if Process.alive?(redis), do: GenServer.stop(redis) end)

    [{:ok, {_serialized, "staging"}}] =
      Exq.Redis.JobQueue.dequeue(redis, namespace, "host", ["staging"])

    assert {:ok, 1} = Exq.Redis.JobQueue.mark_serial_started(redis, namespace, "deferred", first)

    assert {:ok, [{:deferred, _}]} =
             Exq.enqueue_all(__MODULE__, [["staging", Worker, ["nested"], options]])

    assert {:ok, 1} = Exq.Redis.JobQueue.complete_serial(redis, namespace, "deferred", first)
    Exq.subscribe(__MODULE__, "staging")
    spans = receive_spans(4)
    producer = Enum.find(spans, &(attributes(&1)["messaging.exq.enqueue_result"] == "deferred"))
    assert producer != nil
    job = named(spans, "process staging")
    assert_link(job, producer)
    assert_nested(job, spans)
  end

  test "rejected enqueue results mark the producer span as errored" do
    Application.put_env(:exq, :enqueue_middleware, [OpentelemetryExq.EnqueueMiddleware, Reject])
    assert enqueue("nested") == {:error, :blocked}
    producer = named(receive_spans(1), "send default")
    assert attributes(producer)["error.type"] == "_OTHER"
    assert attributes(producer)["messaging.exq.enqueue_result"] == "error"
    assert span(producer, :status) == OpenTelemetry.status(:error, "")
    assert Tracer.current_span_ctx() == :undefined
  end

  test "serialization failures are traced without partially enqueueing a bulk request", %{
    namespace: namespace
  } do
    assert_raise Protocol.UndefinedError, fn ->
      Exq.enqueue_all(__MODULE__, [
        ["default", Worker, ["nested"], []],
        ["mailers", Worker, [make_ref()], []]
      ])
    end

    producer = named(receive_spans(1), "send")
    assert attributes(producer)["error.type"] == "Elixir.Protocol.UndefinedError"
    assert span(producer, :status) == OpenTelemetry.status(:error, "")
    assert :otel_events.list(span(producer, :events)) != []
    assert Tracer.current_span_ctx() == :undefined
    {:ok, redis} = Redix.start_link(Application.fetch_env!(:exq, :url), sync_connect: true)
    assert Redix.command!(redis, ["LLEN", "#{namespace}:queue:default"]) == 0
    assert Redix.command!(redis, ["LLEN", "#{namespace}:queue:mailers"]) == 0
    GenServer.stop(redis)
  end

  test "enqueue exits are traced and re-raised" do
    assert catch_exit(Exq.enqueue(:missing_exq, "default", Worker, ["nested"]))
    producer = named(receive_spans(1), "send default")
    assert attributes(producer)["error.type"] == "_OTHER"
    assert span(producer, :status) == OpenTelemetry.status(:error, "")
    assert Tracer.current_span_ctx() == :undefined
  end

  test "inline enqueue runs the worker and preserves the job ID return value" do
    previous = Exq.Support.Config.get(:queue_adapter)
    Application.put_env(:exq, :queue_adapter, Exq.Adapters.Queue.Mock)
    on_exit(fn -> Application.put_env(:exq, :queue_adapter, previous) end)
    start_supervised!({Exq.Mock, mode: :inline})

    assert Exq.enqueue(__MODULE__, "default", InlineWorker, [["reply"]], jid: "inline-job") ==
             {:ok, "inline-job"}

    assert_received {:inline_result, ["reply"]}

    producer = named(receive_spans(1), "send default")
    assert attributes(producer)["messaging.exq.enqueue_result"] == "ok"
    assert attributes(producer)["messaging.message.id"] == "inline-job"
    refute Map.has_key?(attributes(producer), "error.type")
    assert Tracer.current_span_ctx() == :undefined
  end

  test "records serialized argument bytes, not contents or metadata" do
    args = [%{"name" => "café", "token" => "secret"}]

    for attributes <- traced_job_attributes(args) do
      assert attributes["code.namespace"] == "Example.Worker"
      assert attributes["code.function"] == "perform"
      assert attributes["messaging.message.body.size"] == byte_size(Jason.encode!(args))
      refute Map.has_key?(attributes, "args")
      refute Map.has_key?(attributes, "tenant")
    end
  end

  test "records the size of empty arguments" do
    for attributes <- traced_job_attributes([]) do
      assert attributes["messaging.message.body.size"] == 2
    end
  end

  test "omits body size when argument serialization returns an error" do
    for attributes <- traced_job_attributes([make_ref()]) do
      assert attributes["code.namespace"] == "Example.Worker"
      refute Map.has_key?(attributes, "messaging.message.body.size")
    end
  end

  test "omits body size when a custom serializer raises" do
    previous = Application.fetch_env(:exq, :serializer)

    on_exit(fn ->
      case previous do
        {:ok, serializer} -> Application.put_env(:exq, :serializer, serializer)
        :error -> Application.delete_env(:exq, :serializer)
      end
    end)

    Application.put_env(:exq, :serializer, RaisingSerializer)

    for attributes <- traced_job_attributes([]) do
      assert attributes["code.function"] == "perform"
      refute Map.has_key?(attributes, "messaging.message.body.size")
    end
  end

  test "empty bulk enqueue does not create a producer span" do
    assert Exq.enqueue_all(__MODULE__, []) == {:ok, []}
    refute_receive {:span, _}
  end

  test "rejects an invalid span relationship" do
    Application.put_env(:opentelemetry_exq, :span_relationship, :invalid)

    job = %Exq.Support.Job{
      class: "Example.Worker",
      args: [],
      jid: "invalid-relationship",
      queue: "default",
      enqueued_at: System.system_time(:millisecond) / 1000
    }

    assert_raise ArgumentError, "span_relationship must be :link, :child, or :none", fn ->
      OpentelemetryExq.Middleware.before_work(%Exq.Middleware.Pipeline{assigns: %{job: job}})
    end
  end

  defp traced_job_attributes(args) do
    job = %Exq.Support.Job{
      class: "Example.Worker",
      args: args,
      jid: "attributes",
      queue: "default",
      enqueued_at: System.system_time(:millisecond) / 1000,
      meta: %{"tenant" => "private"}
    }

    enqueue_pipeline = %Exq.Enqueue.Pipeline{operation: :enqueue, jobs: [{job, []}]}

    assert {:ok, "attributes"} =
             OpentelemetryExq.EnqueueMiddleware.around_enqueue(enqueue_pipeline, fn pipeline ->
               [{updated_job, _options}] = pipeline.jobs
               assert updated_job.args == args
               {:ok, updated_job.jid}
             end)

    pipeline =
      OpentelemetryExq.Middleware.before_work(%Exq.Middleware.Pipeline{assigns: %{job: job}})

    OpentelemetryExq.Middleware.after_processed_work(pipeline)
    spans = receive_spans(2)
    Enum.map(spans, &attributes/1)
  end

  defp enqueue(mode, options \\ []) do
    Exq.enqueue(__MODULE__, "default", Worker, [mode], Keyword.put_new(options, :max_retries, 0))
  end

  defp receive_spans(count) do
    for _ <- 1..count do
      assert_receive {:span, exported}, 5_000
      exported
    end
  end

  defp named(spans, name) do
    exported = Enum.find(spans, &(span(&1, :name) == name))
    assert exported != nil, "missing span #{name}"
    exported
  end

  defp attributes(exported) do
    exported
    |> span(:attributes)
    |> :otel_attributes.map()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp assert_link(job, producer) do
    assert [relationship] = :otel_links.list(span(job, :links))
    assert link(relationship, :span_id) == span(producer, :span_id)
    assert link(relationship, :trace_id) == span(producer, :trace_id)
  end

  defp assert_nested(job, spans) do
    child =
      Enum.find(
        spans,
        &(span(&1, :name) == "worker child" and span(&1, :parent_span_id) == span(job, :span_id))
      )

    assert child != nil
    assert span(child, :trace_id) == span(job, :trace_id)
  end
end
