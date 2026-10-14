defmodule Gitpp.Project do
  @moduledoc """
  One GenServer per project: the actor-shaped face of the fold.

  Records arrive as messages (`push_record/2`) and accumulate in arrival
  order — the mailbox *is* the record's arrival channel. The server's held
  set is a projection, never the foundation: kill it, restart it, re-feed it
  the same record list (the log lives outside the process), and the derived
  state — and its digest — are identical. That is the burn/restart property
  the conformance suite's `burn_test` pins.
  """

  use GenServer

  alias Gitpp.{Canon, Fold}

  # ------------------------------------------------------------------ API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :empty, opts)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end

  @doc "Deliver one record to the project (a message, kept in arrival order)."
  def push_record(pid, record), do: GenServer.call(pid, {:push_record, record})

  @doc "Deliver records in bulk (order preserved)."
  def push_records(pid, records) when is_list(records) do
    GenServer.call(pid, {:push_records, records})
  end

  @doc "The records the server currently holds, in arrival order."
  def records(pid), do: GenServer.call(pid, :records)

  @doc "Fold the held record set."
  def derive(pid), do: GenServer.call(pid, :derive)

  @doc """
  SHA-256 (lowercase hex) over the canonical encoding of the derived output —
  the same canonical JSON + SHA-256 discipline as the checkpoint closure root,
  so digests are comparable across the desk, the ports, and this spike.
  """
  def digest(pid) do
    out = derive(pid)
    :crypto.hash(:sha256, Canon.encode!(out)) |> Base.encode16(case: :lower)
  end

  # -------------------------------------------------------------- callbacks

  @impl true
  def init(:empty), do: {:ok, []}

  @impl true
  def handle_call({:push_record, record}, _from, records) do
    {:reply, :ok, records ++ [record]}
  end

  def handle_call({:push_records, new}, _from, records) do
    {:reply, :ok, records ++ new}
  end

  def handle_call(:records, _from, records), do: {:reply, records, records}

  def handle_call(:derive, _from, records) do
    {:reply, Fold.derive(records), records}
  end
end

defmodule Gitpp.ProjectSupervisor do
  @moduledoc """
  A one-for-one supervisor over a single Gitpp.Project. Supervision here is
  the restart half of the doctrine: the process is disposable, the record is
  not — after a crash the supervisor brings back an *empty* project and the
  caller re-feeds the log. Nothing is recovered from the dead process.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    children = [%{id: Gitpp.Project, start: {Gitpp.Project, :start_link, [[]]}}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  def project_pid(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Gitpp.Project, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end
end
