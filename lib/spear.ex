defmodule Spear do
  @moduledoc ~S"""
  A gRPC client for EventStore 20+ backed by Mint.

  ## Streams

  Spear uses Elixir `Stream`s consistency across its API but there are many
  conceptual meanings of "stream" across the systems which Spear composes.
  Consider this call:

  ```elixir
  iex> Spear.stream!(conn, "MyStream", chunk_size: 20) |> Enum.to_list()
  [%Spear.Event{}, %Spear.Event{}, ..]
  ```

  This call

  - reads an EventStore stream
  - over an HTTP2 stream
  - which is typed as a gRPC stream response
  - and is collected into an Elixir `Stream`

  There are four significant concepts for streams in Spear:

  - HTTP2 streams of data
  - gRPC stream requests, responses, and bidirectional communication
  - EventStore streams of events
  - Elixir `Stream`s

  We'll cover each topic separately to avoid confusion.

  #### HTTP2 streams

  HTTP2 streams are channels for data and may be multiplexed: multiple requests
  may stream data in either direction (client to server or server to client)
  at once. HTTP2 streams (and some GenServer tricks) allow Spear to multiplex
  requests and subscriptions in a single HTTP2 connection without blocking.
  Besides concurrency and blocking concerns, HTTP2 streams are mostly an
  implementation detail in Spear.

  #### gRPC streams

  gRPC allows "unary" request-responses similar to a REST request-response
  over HTTP. This resembles synchronous function (or GenServer) calls. The true
  power of gRPC, though, comes from its ability to "stream" requests,
  responses, or requests and responses simultaneously. Consider this RPC
  definition from the EventStore gRPC protobufs:

  ```protobuf
  rpc Read (ReadReq) returns (stream ReadResp);
  ```

  In the `Spear.stream!/3` function, this "stream" response lends itself to
  an Elixir `Stream`. Conceptually the `ReadResp` messages are returned as an
  ordered list of events in an EventStore stream. These response messages are
  returned as quickly as possible and resemble a unary request very closely.

  This same RPC is invoked to implement `Spear.subscribe/4`, though, which
  does not return an Elixir `t:Enumerable.t/0`. Instead this function
  asynchronously signs-up the given process for receiving messages per event.

  gRPC streams may emulate synchronous calls returning lists as with
  `Spear.stream!/3` but are also commonly used to implement asynchronous
  subscription workflows as with `Spear.subscribe/4`.

  gRPC streams may even be fully asynchronous is both directions as with
  EventStore Persistent Subscriptions. This communication is known as
  bidirectional or "bidi-stream" and is covered more fully in the
  `Spear.PersistentSubscription` moduledoc.

  gRPC streams are also an implementation-level detail in Spear and will
  not be mentioned otherwise in this documentation unless specifically called
  a "gRPC stream".

  #### EventStore streams

  EventStore streams are append-only collections of events ordered by the
  timestamp of each event's commit (or commit preparation). Streams can be
  read forwards or backwards and from any revision (a fancy way of saying
  "position in a stream").

  EventStore streams will be referred to in this documentation as EventStore
  streams, or simply "streams" where contextually appropriate.

  #### Elixir Streams

  Elixir `Stream`s are conceptually different than both gRPC/HTTP2 streams
  and EventStore streams. Elixir `Stream`s differ as well from lazy enumerables
  in other languages like Haskell due to the lack of a "thunk" built-in.
  `Stream`s are simply formulas for producing enumerable collections such as
  `List`s.

  Since streams are a formula and not an actual list (or otherwise
  collectable), they can exploit some lovely properties:

  - computations can be done lazily on demand
      - this can reduce memory consumption
  - streams can be composed
  - streams can be infinite

  A common example is reading a large file such as a big CSV. Without streams,
  the entire file must be read into memory and each transformation of each line
  or chunk must be computed in entirety before moving on to the next operation
  (e.g. with `Enum.map/2` or `Enum.reduce/3`). With a file stream, one may read
  a large file line-by-line, perform many `Stream.map/2`s (or similar) and
  eventually perform some side-effect by forcing the stream with `Stream.run/1`
  or an `Enum` function. Only once the first line or chunk has been read from
  the file and run through the pipeline of composed stream functions will the
  next one be read and run through.

  To differentiate, we will most commonly refer to Elixir `Stream`s in the
  Spear documentation by their canonical data-type: `t:Enumerable.t/0`.
  """

  @doc """
  Collects an EventStore stream into an enumerable

  This function may raise in cases where the gRPC requests fail to read events
  from the EventStore (in cases of timeout or unavailability).

  This function does not raise if a stream does not exist (is empty), instead
  returning an empty enumerable `[]`.

  `connection` may be any valid GenServer name (including PIDs) for a process
  running the `Spear.Connection` GenServer.

  `stream_name` can be any stream, existing or not, including projected
  streams such as category streams or event-type streams. The `:all` atom
  may be passed as `stream_name` to read all events in the EventStore.

  ## Options

  * `:from` - (default: `:start`) the EventStore stream revision from which to
    read. Valid values include `:start`, `:end`, any non-negative integer
    representing the event number revision in the stream and events. Event
    numbers are exclusive (e.g. reading from `0` will first return the
    event numbered `1` in the stream, if one exists). `:start` and `:end`
    are treated as inclusive (e.g. `:start` will return the first event in
    the stream).  Events (either `Spear.Event` or ReadResp structs) can also
    be supplied and will be treated as exclusive.
  * `:direction` - (default: `:forwards`) the direction in which to read the
    EventStore stream. Valid values include `:forwards` and `:backwards`.
    Reading the EventStore stream forwards will return events in the order
    in which they were written to the EventStore; reading backwards will
    return events in the opposite order.
  * `:filter` - (default: `nil`) TODO
  * `:resolve_links?` - (default: `true`) whether or not to request that
    link references be resolved. See the moduledocs for more information
    about link resolution.
  * `:chunk_size` - (default: `128`) the number of events to read from the
    EventStore at a time. Any positive integer is valid. See the enumeration
    characteristics section below for more information about how `:chunk_size`
    works and how to tune it.
  * `:timeout` - (default: `5_000` - 5s) the time allowed for the read of a
    single chunk of events in the EventStore stream. This time is _not_
    cumulative: an EventStore stream 100 events long which takes 5s to read
    each chunk may be read in chunks of 20 events culumaltively in 25s. A
    timeout of `5_001`ms would not raise a timeout error in that scenario
    (assuming the chunk read consistently takes `<= 5_000` ms).
  * `:raw?:` - (default: `false`) controls whether or not the enumerable
    `event_stream` is decoded to `Spear.Event` structs from their raw
    `ReadReq` output. Setting `raw?: true` prevents this transformation and
    leaves each event as a `ReadReq` struct. See
    `Spear.Event.from_read_response/2` for more information.

  ## Enumeration Characteristics

  The `event_stream` `t:Enumerable.t/0` returned by this function initially
  contains a buffer of bytes from the first read of the stream `stream_name`.
  This buffer potentially contains up to `:chunk_size` messages when run.
  The enumerable is written as a formula which abstracts away the chunking
  nature of the gRPC requests, however, so even though the EventStore stream is
  read in chunks (per the `:chunk_size` option), the entire EventStore stream
  can be read by running the enumeration (e.g. with `Enum.to_list/1`). Note
  that the stream will make a gRPC request to read more events whenever the
  buffer runs dry with up to `:chunk_size` messages filling the buffer on each
  request.

  `:chunk_size` is difficult to tune as it causes a tradeoff between (gRPC)
  request duration and number of messages added to the buffer. A higher
  `:chunk_size` may hydrate the buffer with more events and reduce the number
  of gRPC requests needed to read an entire stream, but it also increases
  the number of messages that will be sent over the network per request which
  could decrease reliability. Generally speaking, a lower `:chunk_size` is
  appropriate for streams in which the events are large and a higher
  `:chunk_size` is appropriate for streams with many small events. Manual
  tuning and trial-and-error can be used to find a performant `:chunk_size`
  setting for any individual environment.

  ## Examples

      iex> Spear.stream!(MyConnection, "es_supported_clients", chunk_size: 1) |> Enum.take(1)
      [
        %Spear.Event{
          body: %{"languages" => ["typescript", "javascript"], "runtime" => "NodeJS"},
          id: "1fc908c1-af32-4d06-a9bd-3bf86a833fdf",
          metadata: %{..},
          type: "grpc-client"
        }
      ]
      # say we have 5 events in the "es_supported_clients" stream
      iex> Spear.stream!(MyConnection, "es_supported_clients", chunk_size: 3) |> Enum.count()
      5
  """
  @spec stream!(
          connection :: GenServer.name(),
          stream_name :: String.t() | :all,
          opts :: Keyword.t()
        ) ::
          event_stream :: Enumerable.t()
  def stream!(connection, stream_name, opts \\ []) do
    default_stream_opts = [
      from: :start,
      direction: :forwards,
      chunk_size: 128,
      filter: nil,
      resolve_links?: true,
      through: fn stream -> Stream.map(stream, &Spear.Event.from_read_response/1) end,
      timeout: 5_000,
      raw?: false
    ]

    opts = Keyword.merge(default_stream_opts, opts)

    through =
      if opts[:raw?] do
        & &1
      else
        opts[:through]
      end

    Spear.Reading.Stream.new!(
      connection: connection,
      stream: stream_name,
      from: opts[:from],
      max_count: opts[:chunk_size],
      filter: opts[:filter],
      direction: opts[:direction],
      resolve_links?: opts[:resolve_links?],
      timeout: opts[:timeout]
    )
    |> through.()
  end

  @doc """
  Reads a chunk of events from an EventStore stream into an enumerable

  Unlike `stream!/3`, this function will only read one chunk of events at a time
  specified by the `:max_count` option. This function also does not raise in
  cases of error, instead returning an ok- or error-tuple.

  If the `stream_name` EventStore stream does not exist (is empty) and the
  gRPC request succeeds for this function, `{:ok, []}` will be returned.

  ## Options

  * `:from` - (default: `:start`) the EventStore stream revision from which to
    read. Valid values include `:start`, `:end`, any non-negative integer
    representing the event number revision in the stream and events. Event
    numbers are exclusive (e.g. reading from `0` will first return the
    event numbered `0` in the stream, if one exists). `:start` and `:end`
    are treated as inclusive (e.g. `:start` will return the first event in
    the stream).  Events (either `Spear.Event` or ReadResp structs) can also
    be supplied and will be treated as exclusive.
  * `:direction` - (default: `:forwards`) the direction in which to read the
    EventStore stream. Valid values include `:forwards` and `:backwards`.
    Reading the EventStore stream forwards will return events in the order
    in which they were written to the EventStore; reading backwards will
    return events in the opposite order.
  * `:filter` - (default: `nil`) TODO
  * `:resolve_links?` - (default: `true`) whether or not to request that
    link references be resolved. See the moduledocs for more information
    about link resolution.
  * `:max_count` - (default: `42`) the maximum number of events to read from
    the EventStore stream. Any positive integer is valid. Even if the stream
    is longer than this `:max_count` option, only `:max_count` events will
    be returned from this function. `:infinity` is _not_ a valid value for
    `:max_count`. Use `stream!/3` for an enumerable which reads an EventStore
    stream in its entirety in chunked network requests.
  * `:timeout` - (default: `5_000` - 5s) the time allowed for the read of the
    single chunk of events in the EventStore stream. Note that the gRPC request
    which reads events from the EventStore is front-loaded in this function:
    the `:timeout` covers the time it takes to read the events. The timeout
    may be exceeded
  * `:raw?:` - (default: `false`) controls whether or not the enumerable
    `event_stream` is decoded to `Spear.Event` structs from their raw
    `ReadReq` output. Setting `raw?: true` prevents this transformation and
    leaves each event as a `ReadReq` struct. See
    `Spear.Event.from_read_response/2` for more information.

  ## Timing and Timeouts

  The gRPC request which reads events from the EventStore is front-loaded
  in this function: this function returns immediately after receiving all data
  off the wire from the network request. This means that the `:timeout` option
  covers the gRPC request and response time but not any time spend decoding
  the response (see the Enumeration Characteristics section below for more
  details on how the enumerable decodes messages).

  The default timeout of 5s may not be enough time in cases of either reading
  very large numbers of events or reading events with very large bodies.

  Note that _up to_ the `:max_count` of events is returned from this call
  depending on however many events are in the EventStore stream being read.
  When tuning the `:timeout` option, make sure to test against a stream which
  is at least as long as `:max_count` events.

  ## Enumeration Characteristics

  The `event_stream` `t:Enumerable.t/0` returned in the success case of this
  function is a wrapper around the bytes received from the gRPC response. Note
  that when the `{:ok, event_stream}` is returned, the gRPC request has already
  concluded.

  This offers only marginal performance improvement: an enumerable is returned
  mostly for consistency in the Spear API.

  ## Examples

      # say we have 5 events in the stream "es_supported_clients"
      iex> {:ok, events} = Spear.read_stream(conn, "es_supported_clients", max_count: 2)
      iex> events |> Enum.count()
      2
      iex> {:ok, events} = Spear.read_stream(conn, "es_supported_clients", max_count: 10)
      iex> events |> Enum.count()
      5
      iex> events |> Enum.take(1)
      [
        %Spear.Event{
          body: %{"languages" => ["typescript", "javascript"], "runtime" => "NodeJS"},
          id: "1fc908c1-af32-4d06-a9bd-3bf86a833fdf",
          metadata: %{..},
          type: "grpc-client"
        }
      ]
  """
  @spec read_stream(GenServer.name(), String.t(), Keyword.t()) ::
          {:ok, event_stream :: Enumerable.t()} | {:error, any()}
  def read_stream(connection, stream_name, opts \\ []) do
    default_read_opts = [
      from: :start,
      direction: :forwards,
      max_count: 42,
      filter: nil,
      resolve_links?: true,
      through: fn stream -> Stream.map(stream, &Spear.Event.from_read_response/1) end,
      timeout: 5_000,
      raw?: false
    ]

    opts = Keyword.merge(default_read_opts, opts)

    through =
      if opts[:raw?] do
        & &1
      else
        opts[:through]
      end

    chunk_read_response =
      Spear.Reading.Stream.read_chunk(
        connection: connection,
        stream: stream_name,
        from: opts[:from],
        max_count: opts[:max_count],
        filter: opts[:filter],
        direction: opts[:direction],
        resolve_links?: opts[:resolve_links?],
        timeout: opts[:timeout]
      )

    case chunk_read_response do
      {:ok, stream} -> {:ok, through.(stream)}
      error -> error
    end
  end

  @doc """
  Appends a stream of events to an EventStore stream

  `event_stream` is an enumerable which may either be a collection of
  `t:Spear.Event.t/0` structs or more low-level
  `t:Spear.Protos.EventStore.Client.Streams.AppendReq.t/0`
  structs. In cases where the enumerable produces `t:Spear.Event.t/0` structs,
  they will be lazily mapped to `AppendReq` structs before being encoded to
  wire data.

  See the [Writing Events](TODO) guide for more information about writing
  events.

  ## Options

  * `:expect` - (default: `:any`) the expectation to set on the
    status of the stream. The write will fail if the expectation fails. See
    `Spear.ExpectationViolation` for more information about expectations.
  * `:timeout` - (default: `5_000` - 5s) the GenServer timeout for calling
    the RPC.
  * `:raw?` - (default: `false`) a boolean which controls whether the return
    signature should be a simple `:ok | {:error, any()}` or
    `{:ok, AppendResp.t()} | {:error, any()}`. This can be used to extract
    metadata and information from the append response which is not available
    through the simplified return API, such as the stream's revision number
    after writing the events.

  ## Examples

      iex> [Spear.Event.new("es_supported_clients", %{})]
      ...> |> Spear.append(conn, expect: :exists)
      :ok
      iex> [Spear.Event.new("es_supported_clients", %{})]
      ...> |> Spear.append(conn, expect: :empty)
      {:error, %Spear.ExpectationViolation{current: 1, expected: :empty}}
  """
  @spec append(
          event_stream :: Enumerable.t(),
          connection :: GenServer.name(),
          stream_name :: String.t(),
          opts :: Keyword.t()
        ) :: :ok | {:error, reason :: Spear.ExpectationViolation.t() | any()}
  def append(event_stream, conn, stream_name, opts \\ []) when is_binary(stream_name) do
    # TODO gRPC timeout
    default_write_opts = [
      batch_size: 1,
      expect: :any,
      timeout: 5000,
      raw?: false
    ]

    opts =
      default_write_opts
      |> Keyword.merge(opts)
      |> Keyword.merge(event_stream: event_stream, stream: stream_name)

    request = opts |> Enum.into(%{}) |> Spear.Writing.build_write_request()

    with {:ok, %Spear.Connection.Response{} = response} <-
           GenServer.call(conn, {:request, request}, opts[:timeout]),
         %Spear.Grpc.Response{status: :ok, data: %{result: {:success, _}}} <-
           Spear.Grpc.Response.from_connection_response(response) do
      :ok
    else
      {:error, %Spear.Connection.Response{} = response} ->
        {:error, response}

      %Spear.Grpc.Response{
        status: :ok,
        data: %{result: {:wrong_expected_version, expectation_violation}}
      } ->
        {:error, Spear.Writing.map_expectation_violation(expectation_violation)}

      %Spear.Grpc.Response{} = response ->
        {:error, response}
    end
  end

  @doc """
  Subscribes a process to an EventStore stream

  Unlike `read_stream/3` or `stream!/3`, this function does not return an
  enumerable. Instead the `subscriber` process is signed up to receive messages
  for subscription events. Events are emitted in order as info messages with
  the signature

  ```elixir
  {:spear_event, Spear.Event.t()}
  ```

  or this signature if the `raw?: true` option is provided

  ```elixir
  {:spear_event, Spear.Protos.EventStore.Client.Streams.ReadResp.t()}
  ```

  This function will block the caller until the subscription has been
  confirmed by the EventStore.

  ## Options

  * `:from` - (default: `:start`) the EventStore stream revision from which to
    read. Valid values include `:start`, `:end`, any non-negative integer
    representing the event number revision in the stream and events. Event
    numbers are exclusive (e.g. reading from `0` will first return the
    event numbered `1` in the stream, if one exists). `:start` and `:end`
    are treated as inclusive (e.g. `:start` will return the first event in
    the stream).  Events (either `Spear.Event` or ReadResp structs) can also
    be supplied and will be treated as exclusive.
  * `:filter` - (default: `nil`) TODO
  * `:resolve_links?` - (default: `true`) whether or not to request that
    link references be resolved. See the moduledocs for more information
    about link resolution.
  * `:timeout` - (default: `5_000`) the time to wait for the EventStore
    to confirm the subscription request.
  * `:raw?` - (default: `false`) controls whether the events are sent as
    raw `ReadResp` structs or decoded into `t:Spear.Event.t/0`s

  ## Examples

      # say there are 3 events in the EventStore stream "my_stream"
      iex> Spear.subscribe(conn, self(), "my_stream", from: 0)
      {:ok, #Reference<0.1160763861.3015180291.51238>}
      iex> flush
      {:spear_event, %Spear.Event{}} # second event
      {:spear_event, %Spear.Event{}} # third event
      :ok
  """
  @spec subscribe(
          connection :: pid | GenServer.name(),
          subscriber :: pid | GenServer.name(),
          stream_name :: String.t() | :all,
          opts :: Keyword.t()
        ) :: {:ok, subscription_reference :: reference()} | {:error, any()}
  def subscribe(conn, subscriber, stream_name, opts \\ []) do
    default_subscribe_opts = [
      direction: :forwards,
      from: :start,
      filter: nil,
      resolve_links?: true,
      timeout: 5_000,
      raw?: false,
      through: &Spear.Event.from_read_response/1
    ]

    opts =
      default_subscribe_opts
      |> Keyword.merge(opts)
      |> Keyword.merge(stream: stream_name, subscriber: subscriber)

    through =
      if opts[:raw?] do
        & &1
      else
        opts[:through]
      end

    on_data = fn message ->
      subscriber
      |> GenServer.whereis()
      |> send({:spear_event, through.(message)})
    end

    request = opts |> Enum.into(%{}) |> Spear.Reading.build_subscribe_request()

    # TODO deal with broken subscriptions
    GenServer.call(conn, {{:on_data, on_data}, request}, opts[:timeout])
  end

  @doc """
  Cancels a subscription

  This function will cancel a subscription if the provided
  `subscription_reference` exists, but is idempotent: if the
  `subscription_reference` is not an active subscription reference, `:ok` will
  be returned.

  ## Examples

      iex> {:ok, subscription} = Spear.subscribe(conn, self(), "my_stream")
      {:ok, #Reference<0.4293953740.2750676995.30541>}
      iex> Spear.cancel_subscription(conn, subscription)
      :ok
      iex> Spear.cancel_subscription(conn, subscription)
      :ok
  """
  @spec cancel_subscription(
          connection :: pid | GenServer.name(),
          subscription_reference :: reference(),
          timeout()
        ) :: :ok | {:error, any()}
  def cancel_subscription(conn, subscription_reference, timeout \\ 5_000)
      when is_reference(subscription_reference) do
    GenServer.call(conn, {:cancel, subscription_reference}, timeout)
  end

  @doc """
  Deletes an EventStore stream

  EventStore supports two kinds of stream deletions: soft-deletes and
  tombstones. By default this function will perform a soft-delete. Pass the
  `tombstone?: true` option to tombstone the stream.

  Soft-deletes make the events in the specified stream no longer accessible
  through reads. A scavenge operation will reclaim the disk space taken by
  any soft-deleted events. New events may be written to a soft-deleted stream.
  When reading soft-deleted streams, `:from` options of `:start` and `:end`
  will behave as expected, but all events in the stream will have revision
  numbers off-set by the number of deleted events.

  Tombstoned streams may not be written to ever again. Attempting to write
  to a tombstoned stream will fail with a gRPC `:failed_precondition` error

  ```elixir
  iex> [Spear.Event.new("delete_test", %{})] |> Spear.append(conn, "delete_test_0")
  :ok
  iex> Spear.delete_stream(conn, "delete_test_0")
  :ok
  iex> [Spear.Event.new("delete_test", %{})] |> Spear.append(conn, "delete_test_0")
  {:error,
   %Spear.Grpc.Response{
     data: "",
     message: "Event stream 'delete_test_0' is deleted.",
     status: :failed_precondition,
     status_code: 9
   }}
  ```

  ## Options

  * `:tombstone?` - (default: `false`) controls whether the stream is
    soft-deleted or tombstoned.
  * `:timeout` - (default: `5_000` - 5s) the time allowed to block while
    waiting for the EventStore to delete the stream.
  * `:expect` - (default: `:any`) the expected state of the stream when
    performing the deleteion. See `append/4` and `Spear.ExpectationViolation`
    for more information.

  ## Examples

      iex> Spear.append(events, conn, "my_stream")
      :ok
      iex> Spear.delete_stream(conn, "my_stream")
      :ok
  """
  @spec delete_stream(
          connection :: pid | GenServer.name(),
          stream_name :: String.t(),
          opts :: Keyword.t()
        ) :: :ok | {:error, any()}
  def delete_stream(conn, stream_name, opts \\ []) when is_binary(stream_name) do
    default_delete_opts = [
      tombstone?: false,
      timeout: 5_000,
      expect: :any
    ]

    opts =
      default_delete_opts
      |> Keyword.merge(opts)
      |> Keyword.put(:stream, stream_name)

    request = opts |> Enum.into(%{}) |> Spear.Writing.build_delete_request()

    with {:ok, %Spear.Connection.Response{} = response} <-
           GenServer.call(conn, {:request, request}, opts[:timeout]),
         %Spear.Grpc.Response{status: :ok} <-
           Spear.Grpc.Response.from_connection_response(response) do
      :ok
    else
      {:error, %Spear.Connection.Response{} = response} -> {:error, response}
      %Spear.Grpc.Response{} = response -> {:error, response}
    end
  end
end
