defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Manager, Orchestrator}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec repos(Conn.t(), map()) :: Conn.t()
  def repos(conn, _params) do
    case Manager.snapshot(manager()) do
      %{} = snapshot ->
        json(conn, snapshot)

      :unavailable ->
        error_response(conn, 503, "manager_unavailable", "Manager is unavailable")
    end
  end

  @spec repo_state(Conn.t(), map()) :: Conn.t()
  def repo_state(conn, %{"repo_id" => repo_id}) do
    case Manager.repo_state(manager(), repo_id) do
      {:ok, status, payload} ->
        conn
        |> put_status(status)
        |> json(payload)

      {:error, reason} ->
        manager_api_error_response(conn, reason)
    end
  end

  @spec repo_issue(Conn.t(), map()) :: Conn.t()
  def repo_issue(conn, %{"repo_id" => repo_id, "issue_identifier" => issue_identifier}) do
    case Manager.repo_issue(manager(), repo_id, issue_identifier) do
      {:ok, status, payload} ->
        conn
        |> put_status(status)
        |> json(payload)

      {:error, reason} ->
        manager_api_error_response(conn, reason)
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec restart_repo(Conn.t(), map()) :: Conn.t()
  def restart_repo(conn, %{"repo_id" => repo_id}) do
    case Manager.restart_repo(manager(), repo_id) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, reason} ->
        manager_api_error_response(conn, reason)
    end
  end

  @spec restart_manager(Conn.t(), map()) :: Conn.t()
  def restart_manager(conn, _params) do
    case Manager.restart(manager()) do
      :ok ->
        conn
        |> put_status(202)
        |> json(%{queued: true, action: "manager_restart"})

      {:error, :unavailable} ->
        error_response(conn, 503, "manager_unavailable", "Manager is unavailable")
    end
  end

  @spec approve(Conn.t(), map()) :: Conn.t()
  def approve(conn, %{"issue_identifier" => issue_identifier}) do
    case SymphonyElixir.Orchestrator.approve_issue(orchestrator(), issue_identifier) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")

      {:error, :approval_not_pending} ->
        error_response(conn, 409, "approval_not_pending", "Issue has no pending approval request")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Orchestrator
  end

  defp manager do
    Endpoint.config(:manager) || Manager
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp manager_api_error_response(conn, :repo_not_found) do
    error_response(conn, 404, "repo_not_found", "Repo not found")
  end

  defp manager_api_error_response(conn, :repo_disabled) do
    error_response(conn, 409, "repo_disabled", "Repo is disabled")
  end

  defp manager_api_error_response(conn, :repo_unavailable) do
    error_response(conn, 503, "repo_unavailable", "Repo runtime is unavailable")
  end

  defp manager_api_error_response(conn, :unavailable) do
    error_response(conn, 503, "manager_unavailable", "Manager is unavailable")
  end
end
