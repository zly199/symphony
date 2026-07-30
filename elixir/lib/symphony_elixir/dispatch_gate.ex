defmodule SymphonyElixir.DispatchGate do
  @moduledoc """
  Records, per work item, whether the operator has released it to run locally.

  Tracker state says a ticket is worth doing. It does not say the operator wants
  Codex spending tokens on it right now, and only the person watching the
  dashboard can answer that. So intake is deliberately wide — anything the
  tracker has not closed shows up — and dispatch waits here instead: `:waiting`
  until someone presses start, `:started` while the work is live, `:paused` when
  they decide it is going nowhere.

  Absence of a record means `:waiting`, which is what makes "nothing runs until I
  say so" the default for a ticket Symphony has never seen. The file lives beside
  the approvals because it answers the same kind of question: a human decision
  that has to outlive the orchestrator process, since a gate that reopens on
  restart would spend tokens nobody authorized.
  """

  require Logger

  alias SymphonyElixir.StateFile

  @file_name "dispatch_gate.json"

  @statuses ["started", "paused", "review"]

  @type status :: :waiting | :started | :paused | :review

  @type record :: %{
          issue_id: String.t(),
          identifier: String.t() | nil,
          status: status(),
          updated_at: String.t(),
          updated_by: String.t() | nil
        }

  @doc "Returns the gate status for `issue_id`; unknown items are `:waiting`."
  @spec status(String.t() | nil) :: status()
  def status(issue_id) when is_binary(issue_id) do
    case Map.get(load(), issue_id) do
      %{status: status} -> status
      nil -> :waiting
    end
  end

  def status(_issue_id), do: :waiting

  @doc "Returns true when `issue_id` may be dispatched."
  @spec started?(String.t() | nil) :: boolean()
  def started?(issue_id), do: status(issue_id) == :started

  @doc "Returns true when the operator has paused `issue_id`."
  @spec paused?(String.t() | nil) :: boolean()
  def paused?(issue_id), do: status(issue_id) == :paused

  @doc "Returns true when `issue_id` is waiting for operator review."
  @spec review?(String.t() | nil) :: boolean()
  def review?(issue_id), do: status(issue_id) == :review

  @doc "Returns the gate record for `issue_id`, or nil when it is untouched."
  @spec fetch(String.t() | nil) :: record() | nil
  def fetch(issue_id) when is_binary(issue_id), do: Map.get(load(), issue_id)
  def fetch(_issue_id), do: nil

  @doc "Returns `%{issue_id => status}` for every item the operator has decided on."
  @spec statuses() :: %{optional(String.t()) => status()}
  def statuses do
    Map.new(load(), fn {issue_id, record} -> {issue_id, record.status} end)
  end

  @doc """
  Releases `issue_id` for dispatch.

  This is the click that authorizes token spend on a ticket, so it is recorded
  before anything runs rather than inferred from a run that already started.
  """
  @spec start(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def start(issue_id, opts \\ []) when is_binary(issue_id), do: put(issue_id, :started, opts)

  @doc "Holds `issue_id` until it is resumed, whatever its tracker state does."
  @spec pause(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def pause(issue_id, opts \\ []) when is_binary(issue_id), do: put(issue_id, :paused, opts)

  @doc "Hands completed work to the operator and prevents further agent dispatch."
  @spec handoff_for_review(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def handoff_for_review(issue_id, opts \\ []) when is_binary(issue_id),
    do: put(issue_id, :review, opts)

  @doc """
  Returns a held `issue_id` to `:started`.

  Resuming is not the same as starting over: the item was already authorized, so
  it goes back to running rather than back to the queue for another decision.
  """
  @spec resume(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def resume(issue_id, opts \\ []) when is_binary(issue_id), do: put(issue_id, :started, opts)

  @doc """
  Drops the record for `issue_id`, returning it to `:waiting`.

  Called when a ticket reaches a terminal state: leaving `:started` behind would
  silently authorize a run if that ticket were ever reopened.
  """
  @spec forget(String.t()) :: :ok | {:error, term()}
  def forget(issue_id) when is_binary(issue_id) do
    gate = load()

    if Map.has_key?(gate, issue_id) do
      Logger.info("Cleared dispatch gate issue_id=#{issue_id}")

      gate |> Map.delete(issue_id) |> store()
    else
      :ok
    end
  end

  @doc false
  @spec path() :: Path.t()
  def path, do: StateFile.path(@file_name)

  defp put(issue_id, status, opts) do
    record = %{
      "issue_id" => issue_id,
      "identifier" => Keyword.get(opts, :identifier),
      "status" => Atom.to_string(status),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "updated_by" => Keyword.get(opts, :updated_by, "dashboard")
    }

    case load() |> Map.put(issue_id, decode(record)) |> store() do
      :ok ->
        Logger.info("Recorded dispatch gate issue_id=#{issue_id} issue_identifier=#{record["identifier"]} status=#{record["status"]} updated_by=#{record["updated_by"]}")

        {:ok, decode(record)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load do
    @file_name
    |> StateFile.read_map()
    |> Enum.flat_map(fn {issue_id, record} ->
      case decode(record) do
        nil -> []
        decoded -> [{issue_id, decoded}]
      end
    end)
    |> Map.new()
  end

  defp store(gate) do
    StateFile.write_map(@file_name, Map.new(gate, fn {issue_id, record} -> {issue_id, encode(record)} end))
  end

  # An unrecognized status is dropped rather than guessed at: treating an
  # unreadable record as `:waiting` keeps a hand-edited file from authorizing a
  # run nobody asked for.
  defp decode(record) when is_map(record) do
    case record["status"] do
      status when status in @statuses ->
        %{
          issue_id: record["issue_id"],
          identifier: record["identifier"],
          status: String.to_existing_atom(status),
          updated_at: record["updated_at"],
          updated_by: record["updated_by"]
        }

      _other ->
        nil
    end
  end

  defp encode(record) do
    %{
      "issue_id" => record.issue_id,
      "identifier" => record.identifier,
      "status" => Atom.to_string(record.status),
      "updated_at" => record.updated_at,
      "updated_by" => record.updated_by
    }
  end
end
