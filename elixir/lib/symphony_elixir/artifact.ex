defmodule SymphonyElixir.Artifact do
  @moduledoc """
  Stores the deliverable each phase hands to the operator at its gate.

  A gate that asks "is this alright?" without showing what "this" is cannot be
  answered. Analysis used to be the only phase with something to look at, and only
  because the kyuyo workflow happened to write an HTML file into the source
  repository — a convention Symphony read back by guessing at its path. Review and
  summary had nothing at all, so approving them meant trusting a one-line status
  string.

  So the deliverable is a first-class thing here instead: the agent publishes it
  through `symphony_publish_artifact`, Symphony stores it, and the dashboard
  renders it beside the button that acts on it. Nothing about it depends on the
  repository's own layout, which is what lets every phase and every workflow use
  the same mechanism.

  One artifact per phase per work item: republishing replaces it, because a gate
  shows the current answer, not a history of drafts. What the operator said about
  earlier drafts lives in `SymphonyElixir.OperatorFeedback`.
  """

  require Logger

  alias SymphonyElixir.{Config, StateFile}

  @phases [:analysis, :implementation, :summary]
  @phase_names Enum.map(@phases, &Atom.to_string/1)
  @formats ["html", "markdown", "text"]

  # Big enough for a full analysis document with diagrams, small enough that a
  # runaway agent cannot fill the state dir with one call.
  @max_body_bytes 4_000_000
  @max_title_length 200

  @type phase :: :analysis | :implementation | :summary

  @type t :: %{
          issue_id: String.t(),
          identifier: String.t() | nil,
          phase: String.t(),
          title: String.t(),
          format: String.t(),
          body: String.t(),
          bytes: non_neg_integer(),
          published_at: String.t(),
          published_by: String.t() | nil
        }

  @doc "Returns the phases that can carry an artifact, in the order they run."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc """
  Stores `attrs` as `issue_id`'s artifact for `phase`, replacing any earlier one.

  An empty body is rejected: publishing nothing would satisfy the gate check while
  still leaving the operator with nothing to read, which is the exact failure this
  module exists to prevent.
  """
  @spec put(String.t(), phase() | String.t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def put(issue_id, phase, attrs) when is_binary(issue_id) do
    attrs = Map.new(attrs)

    with {:ok, phase} <- normalize_phase(phase),
         {:ok, body} <- normalize_body(attrs),
         {:ok, format} <- normalize_format(attrs) do
      record = %{
        "issue_id" => issue_id,
        "identifier" => get_attr(attrs, :identifier),
        "phase" => phase,
        "title" => normalize_title(get_attr(attrs, :title), phase),
        "format" => format,
        "body" => body,
        "bytes" => byte_size(body),
        "published_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "published_by" => get_attr(attrs, :published_by) || "agent"
      }

      case StateFile.write_map(file_name(issue_id, phase), record) do
        :ok ->
          Logger.info("Published artifact issue_id=#{issue_id} phase=#{phase} format=#{format} bytes=#{record["bytes"]}")

          {:ok, decode(record)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def put(_issue_id, _phase, _attrs), do: {:error, :missing_issue_id}

  @doc "Returns `issue_id`'s artifact for `phase`, or nil when none was published."
  @spec fetch(String.t() | nil, phase() | String.t() | nil) :: t() | nil
  def fetch(issue_id, phase) when is_binary(issue_id) do
    case normalize_phase(phase) do
      {:ok, phase} ->
        case StateFile.read_map(file_name(issue_id, phase)) do
          %{"body" => _} = record -> decode(record)
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  def fetch(_issue_id, _phase), do: nil

  @doc "Returns true when `issue_id` published an artifact for `phase`."
  @spec exists?(String.t() | nil, phase() | String.t() | nil) :: boolean()
  def exists?(issue_id, phase), do: not is_nil(fetch(issue_id, phase))

  @doc """
  Returns every artifact `issue_id` has published, in phase order.

  The operator reviewing an implementation still wants the analysis it was built
  against, so the gate shows its own deliverable first and keeps the earlier ones
  reachable.
  """
  @spec list(String.t() | nil) :: [t()]
  def list(issue_id) when is_binary(issue_id) do
    Enum.flat_map(@phases, fn phase ->
      case fetch(issue_id, phase) do
        nil -> []
        artifact -> [artifact]
      end
    end)
  end

  def list(_issue_id), do: []

  @doc "Drops every artifact recorded for `issue_id`."
  @spec clear(String.t()) :: :ok
  def clear(issue_id) when is_binary(issue_id) do
    issue_id |> directory() |> File.rm_rf()
    :ok
  end

  def clear(_issue_id), do: :ok

  @doc false
  @spec directory(String.t()) :: Path.t()
  def directory(issue_id) when is_binary(issue_id) do
    Path.join([Config.state_dir(), "artifacts", storage_key(issue_id)])
  end

  defp file_name(issue_id, phase) do
    Path.join(["artifacts", storage_key(issue_id), "#{phase}.json"])
  end

  # Ids come from trackers, not from Symphony, so they are reduced to characters
  # that cannot walk out of the artifacts directory before becoming a path. The
  # dot goes with the separators: keeping it would leave `..` spellable, and no
  # tracker id needs one.
  defp storage_key(issue_id) do
    case String.replace(issue_id, ~r/[^A-Za-z0-9_-]/, "-") do
      "" -> "unnamed"
      key -> String.slice(key, 0, 120)
    end
  end

  defp normalize_phase(phase) when phase in @phases, do: {:ok, Atom.to_string(phase)}
  defp normalize_phase(phase) when phase in @phase_names, do: {:ok, phase}

  defp normalize_phase(phase) when is_binary(phase) do
    case String.downcase(String.trim(phase)) do
      normalized when normalized in @phase_names -> {:ok, normalized}
      _ -> {:error, :unknown_phase}
    end
  end

  defp normalize_phase(_phase), do: {:error, :unknown_phase}

  defp normalize_body(attrs) do
    case get_attr(attrs, :body) do
      body when is_binary(body) ->
        cond do
          String.trim(body) == "" -> {:error, :empty_body}
          byte_size(body) > @max_body_bytes -> {:error, :body_too_large}
          true -> {:ok, body}
        end

      _ ->
        {:error, :empty_body}
    end
  end

  defp normalize_format(attrs) do
    case get_attr(attrs, :format) do
      nil -> {:ok, "markdown"}
      format when is_binary(format) -> validate_format(String.downcase(String.trim(format)))
      _ -> {:error, :unknown_format}
    end
  end

  defp validate_format(format) when format in @formats, do: {:ok, format}
  defp validate_format("md"), do: {:ok, "markdown"}
  defp validate_format("plain"), do: {:ok, "text"}
  defp validate_format(_format), do: {:error, :unknown_format}

  defp normalize_title(title, phase) when is_binary(title) do
    case String.trim(title) do
      "" -> default_title(phase)
      trimmed -> String.slice(trimmed, 0, @max_title_length)
    end
  end

  defp normalize_title(_title, phase), do: default_title(phase)

  defp default_title("analysis"), do: "系分文档"
  defp default_title("implementation"), do: "实现与 CI 结果"
  defp default_title("summary"), do: "MR 总结"
  defp default_title(_phase), do: "产物"

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp decode(record) do
    %{
      issue_id: record["issue_id"],
      identifier: record["identifier"],
      phase: record["phase"],
      title: record["title"],
      format: record["format"],
      body: record["body"],
      bytes: record["bytes"] || byte_size(record["body"] || ""),
      published_at: record["published_at"],
      published_by: record["published_by"]
    }
  end
end
