defmodule SymphonyElixir.Backlog.AgentTool do
  @moduledoc """
  Provider-native Backlog REST tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.Backlog.Client

  @backlog_api_tool "backlog_api"
  @allowed_methods ["GET", "POST", "PATCH", "DELETE"]
  @backlog_api_description """
  Execute a Backlog API v2 request using Symphony's configured host-side auth.
  """
  @backlog_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "Backlog API method."
      },
      "path" => %{
        "type" => "string",
        "description" => "Relative Backlog API v2 path such as /issues/PROJECT-1/comments."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters. Do not include apiKey.",
        "additionalProperties" => true
      },
      "form" => %{
        "type" => ["object", "null"],
        "description" => "Optional application/x-www-form-urlencoded request fields.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @backlog_api_tool -> execute_backlog_api(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @backlog_api_tool,
        "description" => @backlog_api_description,
        "inputSchema" => @backlog_api_input_schema
      }
    ]
  end

  defp execute_backlog_api(arguments, opts) do
    backlog_client = Keyword.get(opts, :backlog_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, query, form} <- normalize_arguments(arguments),
         {:ok, %{status: status, body: response_body}} <-
           backlog_client.(method, path, query, form, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:backlog_unknown_payload))
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, query} <- normalize_map(Map.get(arguments, "query"), :invalid_query),
         {:ok, form} <- normalize_map(Map.get(arguments, "form"), :invalid_form),
         :ok <- reject_api_key(query),
         :ok <- reject_api_key(form) do
      {:ok, method, path, query, form}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and not String.starts_with?(trimmed, "//") and
         not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) and
         not traversal_path?(trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp traversal_path?(path) do
    path
    |> String.split("/")
    |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp normalize_map(nil, _error), do: {:ok, %{}}
  defp normalize_map(value, _error) when is_map(value), do: {:ok, value}
  defp normalize_map(_value, error), do: {:error, error}

  defp reject_api_key(map) do
    if Enum.any?(Map.keys(map), &(String.downcase(to_string(&1)) == "apikey")) do
      {:error, :api_key_not_allowed}
    else
      :ok
    end
  end

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "backlog_api expects an object with method and path."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "backlog_api.method must be GET, POST, PATCH, or DELETE."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "backlog_api.path must be a safe relative Backlog API v2 path."}}
  end

  defp tool_error_payload(:invalid_query) do
    %{"error" => %{"message" => "backlog_api.query must be a JSON object when provided."}}
  end

  defp tool_error_payload(:invalid_form) do
    %{"error" => %{"message" => "backlog_api.form must be a JSON object when provided."}}
  end

  defp tool_error_payload(:api_key_not_allowed) do
    %{"error" => %{"message" => "backlog_api credentials are supplied by Symphony."}}
  end

  defp tool_error_payload(:missing_backlog_api_key) do
    %{
      "error" => %{
        "message" => "Symphony is missing Backlog auth. Set tracker.provider.api_key or export BACKLOG_API_KEY."
      }
    }
  end

  defp tool_error_payload({:backlog_api_request, _reason}) do
    %{
      "error" => %{
        "message" => "Backlog API request failed before receiving a successful response."
      }
    }
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "Backlog API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
