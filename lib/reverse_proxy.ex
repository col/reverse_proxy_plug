defmodule ReverseProxy do
  require Logger
  alias Plug.Conn

  @behaviour Plug

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, opts) do
    upstream =
      Keyword.get(opts, :upstream, "")
      |> URI.parse()
      |> Map.to_list()
      |> Enum.filter(fn {_, val} -> !!val end)
      |> keyword_rename(:path, :request_path)
      |> keyword_rename(:query, :query_path)

    opts = opts |> Keyword.merge(upstream)

    retreive(conn, opts)
  end

  defp keyword_rename(keywords, old_key, new_key),
    do:
      keywords
      |> Keyword.put(new_key, keywords[old_key])
      |> Keyword.delete(old_key)

  def retreive(conn, options) do
    {method, url, body, headers} = prepare_request(conn, options)
    Logger.debug("Proxying to #{url}")

    HTTPoison.request(
      method,
      url,
      body,
      headers,
      timeout: :infinity,
      recv_timeout: :infinity,
      stream_to: self()
    )

    stream_response(conn)
  end

  @spec stream_response(Conn.t()) :: Conn.t()
  defp stream_response(conn) do
    receive do
      %HTTPoison.AsyncStatus{code: code} ->
        conn
        |> Conn.put_status(code)
        |> stream_response

      %HTTPoison.AsyncHeaders{headers: headers} ->
        conn
        |> put_resp_headers(headers)
        |> Conn.send_chunked(conn.status)
        |> stream_response

      %HTTPoison.AsyncChunk{chunk: chunk} ->
        case Conn.chunk(conn, chunk) do
          {:ok, conn} ->
            stream_response(conn)

          {:error, :closed} ->
            Logger.debug("Client closed before chunk streaming ended")
            conn
        end

      %HTTPoison.AsyncEnd{} ->
        conn
    end
  end

  defp prepare_url(conn, overrides) do
    keys = [:scheme, :host, :port, :query_string]

    x =
      conn
      |> Map.to_list()
      |> Enum.filter(fn {key, _} -> key in keys end)
      |> Keyword.merge(Enum.filter(overrides, fn {_, val} -> !!val end))

    request_path = Enum.join(conn.path_info, "/")

    request_path =
      case request_path do
        "" -> request_path
        path -> "/" <> path
      end

    url = "#{x[:scheme]}://#{x[:host]}:#{x[:port]}#{overrides[:request_path]}#{request_path}"

    case x[:query_string] do
      "" -> url
      query_string -> url <> "?" <> query_string
    end
  end

  defp prepare_request(conn, options) do
    conn =
      conn
      |> Conn.put_req_header(
        "x-forwarded-for",
        conn.remote_ip |> :inet.ntoa() |> to_string
      )
      |> Conn.delete_req_header("transfer-encoding")

    method = conn.method |> String.downcase() |> String.to_atom()
    url = prepare_url(conn, options)
    headers = conn.req_headers

    headers =
      if options[:preserve_host_header],
        do: headers,
        else: List.keyreplace(headers, "host", 0, {"host", options[:host]})

    body = read_body(conn)

    {method, url, body, headers}
  end

  defp read_body(conn) do
    case Conn.read_body(conn) do
      {:ok, body, _conn} ->
        body

      {:more, body, conn} ->
        {:stream,
         Stream.resource(
           fn -> {body, conn} end,
           fn
             {body, conn} ->
               {[body], conn}

             nil ->
               {:halt, nil}

             conn ->
               case Conn.read_body(conn) do
                 {:ok, body, _conn} ->
                   {[body], nil}

                 {:more, body, conn} ->
                   {[body], conn}
               end
           end,
           fn _ -> nil end
         )}
    end
  end

  @spec put_resp_headers(Conn.t(), [{String.t(), String.t()}]) :: Conn.t()
  defp put_resp_headers(conn, []), do: conn

  defp put_resp_headers(conn, [{header, value} | rest]) do
    conn
    |> Conn.put_resp_header(header |> String.downcase(), value)
    |> put_resp_headers(rest)
  end
end
