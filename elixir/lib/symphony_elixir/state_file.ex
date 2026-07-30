defmodule SymphonyElixir.StateFile do
  @moduledoc """
  Reads and writes the small JSON documents Symphony keeps in its state dir.

  Operator decisions outlive the orchestrator process, so they belong on disk
  rather than in GenServer state. Each document is rewritten whole and moved into
  place, which keeps a crash from leaving a half-written file behind, and an
  unreadable document degrades to "empty" so a corrupt file never takes the
  orchestrator down with it.
  """

  require Logger

  alias SymphonyElixir.Config

  @doc "Returns the absolute path of `file_name` inside the state dir."
  @spec path(String.t()) :: Path.t()
  def path(file_name) when is_binary(file_name), do: Path.join(Config.state_dir(), file_name)

  @doc "Returns the decoded map in `file_name`, or an empty map when unreadable."
  @spec read_map(String.t()) :: map()
  def read_map(file_name) when is_binary(file_name) do
    file = path(file_name)

    with {:ok, body} <- File.read(file),
         {:ok, %{} = decoded} <- Jason.decode(body) do
      decoded
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning("Ignoring unreadable state file path=#{file} reason=#{inspect(other)}")

        %{}
    end
  end

  @doc "Writes `contents` to `file_name` atomically."
  @spec write_map(String.t(), map()) :: :ok | {:error, term()}
  def write_map(file_name, contents) when is_binary(file_name) and is_map(contents) do
    file = path(file_name)
    temp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, body} <- Jason.encode(contents, pretty: true),
         :ok <- File.write(temp, body),
         :ok <- File.rename(temp, file) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to persist state file path=#{file} reason=#{inspect(reason)}")

        {:error, reason}
    end
  end
end
