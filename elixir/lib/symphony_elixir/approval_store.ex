defmodule SymphonyElixir.ApprovalStore do
  @moduledoc """
  Records operator approval to move a work item from analysis into implementation.

  Approval is a human decision, so it must survive an orchestrator restart that
  in-memory state would lose. The store is a small JSON file rewritten
  atomically; traffic is one read per dispatch and one write per approval, so a
  plain module beats a supervised process here.
  """

  require Logger

  alias SymphonyElixir.StateFile

  @file_name "approvals.json"

  @type record :: %{
          issue_id: String.t(),
          identifier: String.t() | nil,
          approved_at: String.t(),
          approved_by: String.t() | nil
        }

  @doc "Returns true when `issue_id` has been approved for implementation."
  @spec approved?(String.t() | nil) :: boolean()
  def approved?(issue_id) when is_binary(issue_id), do: Map.has_key?(load(), issue_id)
  def approved?(_issue_id), do: false

  @doc "Returns the approval record for `issue_id`, or nil."
  @spec fetch(String.t() | nil) :: record() | nil
  def fetch(issue_id) when is_binary(issue_id), do: Map.get(load(), issue_id)
  def fetch(_issue_id), do: nil

  @doc "Records approval for `issue_id`. Re-approving refreshes the record."
  @spec approve(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def approve(issue_id, opts \\ []) when is_binary(issue_id) do
    record = %{
      "issue_id" => issue_id,
      "identifier" => Keyword.get(opts, :identifier),
      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "approved_by" => Keyword.get(opts, :approved_by, "dashboard")
    }

    case load() |> Map.put(issue_id, record) |> store() do
      :ok ->
        Logger.info("Recorded analysis approval issue_id=#{issue_id} identifier=#{inspect(record["identifier"])}")

        {:ok, atomize(record)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Drops the approval for `issue_id` so the next run returns to analysis."
  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(issue_id) when is_binary(issue_id) do
    load() |> Map.delete(issue_id) |> store()
  end

  @doc false
  @spec path() :: Path.t()
  def path, do: StateFile.path(@file_name)

  defp load do
    @file_name
    |> StateFile.read_map()
    |> Map.new(fn {issue_id, record} -> {issue_id, atomize(record)} end)
  end

  defp store(approvals), do: StateFile.write_map(@file_name, approvals)

  defp atomize(record) when is_map(record) do
    %{
      issue_id: record["issue_id"] || record[:issue_id],
      identifier: record["identifier"] || record[:identifier],
      approved_at: record["approved_at"] || record[:approved_at],
      approved_by: record["approved_by"] || record[:approved_by]
    }
  end
end
