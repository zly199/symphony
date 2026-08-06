defmodule SymphonyElixir.CodexTranscript do
  @moduledoc """
  Keeps the whole Codex event stream of a run on disk so a finished run can still
  be read back.

  The dashboard's activity column is a 25-entry ring of one-line summaries, which
  is the right shape for watching a run and the wrong shape for explaining one.
  When a phase ends without publishing an artifact the operator is left with
  "turn completed" and nothing else: whether the agent answered in prose instead
  of calling `symphony_publish_artifact`, hit a failing tool call, or ran out of
  turns mid-thought is exactly the difference that ring throws away.

  So every message the app-server sends is appended here verbatim, one JSON
  object per line, under the state dir rather than the workspace — a worktree is
  deleted, and the question "what happened in that run" is usually asked after it
  is gone. Files are per run, newest last, and a run that produces an absurd
  amount of output stops being recorded rather than filling the disk.
  """

  require Logger

  alias SymphonyElixir.Config

  # A long implementation run streams a lot of command output. This is generous
  # enough to hold a full run's events and small enough that a runaway agent
  # cannot fill the state dir with one session.
  @max_file_bytes 32_000_000
  # Runs per issue kept on disk. Older ones are dropped when a new run starts.
  @max_runs_per_issue 20

  @type handle :: %{path: Path.t() | nil, device: pid() | nil, bytes: :counters.counters_ref() | nil}

  @doc """
  Opens a transcript file for a new run of `issue_id` and returns its handle.

  Recording is best-effort: a transcript that cannot be opened must not take the
  run down with it, so failures degrade to a handle that drops what it is given.
  """
  @spec start_run(String.t() | nil, keyword()) :: handle()
  def start_run(issue_id, opts \\ [])

  def start_run(issue_id, opts) when is_binary(issue_id) do
    directory = directory(issue_id)
    path = Path.join(directory, run_file_name())

    with :ok <- File.mkdir_p(directory),
         {:ok, device} <- File.open(path, [:append, :binary]) do
      prune_old_runs(directory)

      handle = %{path: path, device: device, bytes: :counters.new(1, [:write_concurrency])}

      record(handle, %{
        event: :transcript_opened,
        timestamp: DateTime.utc_now(),
        issue_id: issue_id,
        identifier: Keyword.get(opts, :identifier),
        phase: Keyword.get(opts, :phase),
        workspace: Keyword.get(opts, :workspace),
        worker_host: Keyword.get(opts, :worker_host)
      })

      handle
    else
      {:error, reason} ->
        Logger.warning("Failed to open codex transcript issue_id=#{issue_id} path=#{path} reason=#{inspect(reason)}")

        disabled()
    end
  end

  def start_run(_issue_id, _opts), do: disabled()

  @doc "Appends `update` to `handle`'s transcript."
  @spec record(handle(), map()) :: :ok
  def record(%{device: device, bytes: counter}, update)
      when is_pid(device) and is_map(update) and not is_nil(counter) do
    if :counters.get(counter, 1) < @max_file_bytes do
      line = encode_line(update)
      :counters.add(counter, 1, byte_size(line))
      IO.binwrite(device, line)
    end

    :ok
  rescue
    error ->
      Logger.warning("Failed to append to codex transcript: #{inspect(error)}")
      :ok
  end

  def record(_handle, _update), do: :ok

  @doc "Closes `handle`, noting why the run ended."
  @spec finish(handle(), term()) :: :ok
  def finish(%{device: device} = handle, outcome) when is_pid(device) do
    record(handle, %{
      event: :transcript_closed,
      timestamp: DateTime.utc_now(),
      outcome: inspect(outcome)
    })

    File.close(device)
    :ok
  end

  def finish(_handle, _outcome), do: :ok

  @doc """
  Returns `issue_id`'s recorded runs, newest first.

  Each entry carries the path, the file's size, and the run's start time, which is
  what the dashboard needs to offer them without reading any of them.
  """
  @spec runs(String.t() | nil) :: [%{name: String.t(), path: Path.t(), bytes: non_neg_integer(), recorded_at: String.t() | nil}]
  def runs(issue_id) when is_binary(issue_id) do
    directory = directory(issue_id)

    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort(:desc)
        |> Enum.map(fn name ->
          path = Path.join(directory, name)

          %{
            name: name,
            path: path,
            bytes: file_size(path),
            recorded_at: recorded_at(name)
          }
        end)

      {:error, _reason} ->
        []
    end
  end

  def runs(_issue_id), do: []

  @doc """
  Returns the decoded events of `issue_id`'s run named `name`, oldest first.

  `name` comes from a URL, so it is matched against the recorded runs rather than
  joined onto a path: nothing a request can spell reaches a file this issue did
  not record.
  """
  @spec read(String.t() | nil, String.t() | nil) :: {:ok, String.t(), [map()]} | {:error, :not_found}
  def read(issue_id, name \\ nil)

  def read(issue_id, name) when is_binary(issue_id) do
    case select_run(runs(issue_id), name) do
      nil ->
        {:error, :not_found}

      run ->
        events =
          run.path
          |> File.stream!([:line])
          |> Stream.map(&decode_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, run.name, events}
    end
  rescue
    error ->
      Logger.warning("Failed to read codex transcript issue_id=#{issue_id} reason=#{inspect(error)}")

      {:error, :not_found}
  end

  def read(_issue_id, _name), do: {:error, :not_found}

  @doc "Drops every transcript recorded for `issue_id`."
  @spec clear(String.t()) :: :ok
  def clear(issue_id) when is_binary(issue_id) do
    issue_id |> directory() |> File.rm_rf()
    :ok
  end

  def clear(_issue_id), do: :ok

  @doc false
  @spec directory(String.t()) :: Path.t()
  def directory(issue_id) when is_binary(issue_id) do
    Path.join([Config.state_dir(), "transcripts", storage_key(issue_id)])
  end

  defp disabled, do: %{path: nil, device: nil, bytes: nil}

  defp select_run(runs, nil), do: List.first(runs)
  defp select_run(runs, name) when is_binary(name), do: Enum.find(runs, &(&1.name == name))
  defp select_run(runs, _name), do: List.first(runs)

  defp run_file_name do
    stamp =
      DateTime.utc_now()
      |> DateTime.truncate(:millisecond)
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9TZ.]/, "")

    "#{stamp}.jsonl"
  end

  defp recorded_at(name) when is_binary(name) do
    with [stamp | _] <- String.split(name, ".jsonl"),
         {:ok, at, _offset} <- parse_basic_stamp(stamp) do
      at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  defp parse_basic_stamp(<<year::binary-4, month::binary-2, day::binary-2, "T", hour::binary-2, minute::binary-2, second::binary-2, _rest::binary>>) do
    DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z")
  end

  defp parse_basic_stamp(_stamp), do: :error

  defp prune_old_runs(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort(:desc)
        |> Enum.drop(@max_runs_per_issue)
        |> Enum.each(&File.rm(Path.join(directory, &1)))

      {:error, _reason} ->
        :ok
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # The app-server's own line is kept verbatim under `raw` when there is one, so
  # a transcript can answer questions this module never anticipated. Everything
  # else is reduced to something `Jason` will take.
  defp encode_line(update) do
    payload = %{
      "at" => timestamp_string(Map.get(update, :timestamp)),
      "event" => to_string(Map.get(update, :event) || "unknown"),
      "raw" => Map.get(update, :raw),
      "details" => update |> Map.drop([:timestamp, :event, :raw, :payload]) |> jsonable()
    }

    payload =
      case Map.get(update, :payload) do
        nil -> payload
        parsed -> Map.put(payload, "payload", jsonable(parsed))
      end

    Jason.encode!(payload) <> "\n"
  rescue
    _error -> Jason.encode!(%{"at" => nil, "event" => "unencodable", "raw" => inspect(update)}) <> "\n"
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} -> event
      _ -> nil
    end
  end

  defp timestamp_string(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp_string(timestamp) when is_binary(timestamp), do: timestamp
  defp timestamp_string(_timestamp), do: nil

  defp jsonable(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {to_string(key), jsonable(inner)} end)
  end

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp jsonable(value) when is_atom(value), do: to_string(value)
  defp jsonable(value), do: inspect(value)

  # Ids come from trackers, not from Symphony, so they are reduced to characters
  # that cannot walk out of the transcripts directory before becoming a path.
  defp storage_key(issue_id) do
    case String.replace(issue_id, ~r/[^A-Za-z0-9_-]/, "-") do
      "" -> "unnamed"
      key -> String.slice(key, 0, 120)
    end
  end
end
