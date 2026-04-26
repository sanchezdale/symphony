defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Manager
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:mode, dashboard_mode())
      |> assign(:notice, nil)
      |> assign(:payload, empty_payload())
      |> assign(:repos, [])
      |> assign(:selected_repo, nil)
      |> assign(:selected_repo_id, nil)
      |> assign(:now, DateTime.utc_now())
      |> reload_dashboard(nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:notice, nil)
     |> reload_dashboard(params["repo"])}
  end

  @impl true
  def handle_event("select_repo", %{"repo" => repo_id}, socket) do
    {:noreply, push_patch(socket, to: repo_path(repo_id))}
  end

  def handle_event("restart_repo", _params, %{assigns: %{selected_repo: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("restart_repo", _params, socket) do
    repo_id = socket.assigns.selected_repo.id

    next_socket =
      case Manager.restart_repo(manager(), repo_id) do
        {:ok, _payload} ->
          socket
          |> put_notice(:info, "Repo restart queued for #{repo_id}.")
          |> reload_dashboard(repo_id)

        {:error, reason} ->
          socket
          |> put_notice(:error, repo_restart_error(reason))
          |> reload_dashboard(repo_id)
      end

    {:noreply, next_socket}
  end

  @impl true
  def handle_event("restart_manager", _params, socket) do
    next_socket =
      case Manager.restart(manager()) do
        :ok ->
          socket
          |> put_notice(:info, "Manager restart queued.")
          |> reload_dashboard(socket.assigns.selected_repo_id)

        {:error, :unavailable} ->
          put_notice(socket, :error, "Manager is unavailable.")
      end

    {:noreply, next_socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply,
     if socket.assigns.mode == :manager do
       reload_dashboard(socket, socket.assigns.selected_repo_id)
     else
       assign(socket, :now, DateTime.utc_now())
     end}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, reload_dashboard(socket, socket.assigns.selected_repo_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              <%= dashboard_copy(@mode, @selected_repo) %>
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>

            <%= if @mode == :manager do %>
              <span class="status-badge status-badge-mode">
                Managed repos: <%= length(@repos) %>
              </span>
            <% end %>
          </div>
        </div>
      </header>

      <%= if @notice do %>
        <section class={notice_card_class(@notice.tone)}>
          <p class="notice-copy"><%= @notice.message %></p>
        </section>
      <% end %>

      <%= if @mode == :manager do %>
        <section class="section-card repo-control-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Repo controls</h2>
              <p class="section-copy">
                Switch between managed repos and trigger restart actions without leaving the dashboard.
              </p>
            </div>

            <div class="control-actions">
              <button
                :if={@selected_repo}
                type="button"
                phx-click="restart_repo"
                disabled={restart_repo_disabled?(@selected_repo)}
              >
                Restart Repo
              </button>

              <button type="button" class="secondary" phx-click="restart_manager">
                Restart Manager
              </button>
            </div>
          </div>

          <%= if @repos == [] do %>
            <p class="empty-state">No managed repos are configured.</p>
          <% else %>
            <div class="repo-picker">
              <button
                :for={repo <- @repos}
                type="button"
                class={repo_button_class(repo, @selected_repo_id)}
                phx-click="select_repo"
                phx-value-repo={repo.id}
              >
                <div class="repo-pill-header">
                  <span class="repo-pill-name"><%= repo.name %></span>
                  <span class={repo_health_badge_class(repo.health)}>
                    <%= humanize_repo_health(repo.health) %>
                  </span>
                </div>
                <span class="repo-pill-meta mono">
                  <%= repo.id %> · <%= repo_port_label(repo.port) %>
                </span>
              </button>
            </div>

            <%= if @selected_repo do %>
              <div class="repo-summary-grid">
                <article class="metric-card repo-summary-card">
                  <p class="metric-label">Selected repo</p>
                  <p class="summary-value"><%= @selected_repo.name %></p>
                  <p class="metric-detail mono"><%= @selected_repo.id %></p>
                </article>

                <article class="metric-card repo-summary-card">
                  <p class="metric-label">Runtime state</p>
                  <p class="summary-value"><%= humanize_repo_health(@selected_repo.health) %></p>
                  <p class="metric-detail"><%= repo_health_copy(@selected_repo) %></p>
                </article>

                <article class="metric-card repo-summary-card">
                  <p class="metric-label">Endpoint</p>
                  <p class="summary-value mono"><%= repo_endpoint(@selected_repo) %></p>
                  <p class="metric-detail mono"><%= @selected_repo.repo_path %></p>
                </article>

                <article class="metric-card repo-summary-card">
                  <p class="metric-label">Last error</p>
                  <p class="summary-value summary-value-compact"><%= repo_last_error(@selected_repo) %></p>
                  <p class="metric-detail">
                    Restart attempts <%= @selected_repo.restart_attempts %> · Failures <%= @selected_repo.failure_count %>
                  </p>
                </article>
              </div>
            <% end %>
          <% end %>
        </section>
      <% end %>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail"><%= running_metric_copy(@mode) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail"><%= retry_metric_copy(@mode) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy"><%= rate_limit_copy(@mode) %></p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy"><%= running_section_copy(@mode) %></p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={issue_details_path(entry.issue_identifier, @mode, @selected_repo_id)}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy"><%= retry_section_copy(@mode) %></p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={issue_details_path(entry.issue_identifier, @mode, @selected_repo_id)}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp reload_dashboard(socket, requested_repo_id) do
    case socket.assigns.mode do
      :manager ->
        {repos, selected_repo, payload} = load_manager_dashboard(requested_repo_id)

        socket
        |> assign(:repos, repos)
        |> assign(:selected_repo, selected_repo)
        |> assign(:selected_repo_id, selected_repo && selected_repo.id)
        |> assign(:payload, payload)
        |> assign(:now, DateTime.utc_now())

      :runtime ->
        socket
        |> assign(:repos, [])
        |> assign(:selected_repo, nil)
        |> assign(:selected_repo_id, nil)
        |> assign(:payload, normalize_state_payload(Presenter.state_payload(orchestrator(), snapshot_timeout_ms())))
        |> assign(:now, DateTime.utc_now())
    end
  end

  defp load_manager_dashboard(requested_repo_id) do
    case Manager.snapshot(manager()) do
      %{} = snapshot ->
        repos = Enum.sort_by(snapshot.repos, & &1.id)
        selected_repo = select_repo(repos, requested_repo_id)
        {repos, selected_repo, load_manager_payload(selected_repo)}

      :unavailable ->
        {[], nil, unavailable_payload("manager_unavailable", "Manager is unavailable")}
    end
  end

  defp load_manager_payload(nil), do: empty_payload()

  defp load_manager_payload(repo) do
    case Manager.repo_state(manager(), repo.id) do
      {:ok, _status, payload} ->
        normalize_state_payload(payload)

      {:error, :repo_disabled} ->
        unavailable_payload("repo_disabled", "Repo is disabled in manager config.")

      {:error, :repo_not_found} ->
        unavailable_payload("repo_not_found", "Repo not found.")

      {:error, :repo_unavailable} ->
        unavailable_payload("repo_unavailable", repo_health_copy(repo))

      {:error, :unavailable} ->
        unavailable_payload("manager_unavailable", "Manager is unavailable")
    end
  end

  defp dashboard_mode do
    if is_nil(Endpoint.config(:manager)), do: :runtime, else: :manager
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp manager do
    Endpoint.config(:manager) || Manager
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp empty_payload(error \\ nil) do
    %{
      generated_at: generated_at(),
      counts: %{running: 0, retrying: 0},
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      error: error
    }
  end

  defp unavailable_payload(code, message) do
    empty_payload(%{code: code, message: message})
  end

  defp generated_at do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp normalize_state_payload(payload) when is_map(payload) do
    base = empty_payload()

    %{
      generated_at: read(payload, :generated_at, base.generated_at),
      counts: %{
        running: payload |> read(:counts, %{}) |> read(:running, 0) |> normalize_integer(),
        retrying: payload |> read(:counts, %{}) |> read(:retrying, 0) |> normalize_integer()
      },
      running:
        payload
        |> read(:running, [])
        |> normalize_list()
        |> Enum.map(&normalize_running_entry/1),
      retrying:
        payload
        |> read(:retrying, [])
        |> normalize_list()
        |> Enum.map(&normalize_retry_entry/1),
      codex_totals: normalize_codex_totals(read(payload, :codex_totals, %{})),
      rate_limits: read(payload, :rate_limits),
      error: normalize_error(read(payload, :error))
    }
  end

  defp normalize_running_entry(entry) do
    %{
      issue_id: read(entry, :issue_id),
      issue_identifier: read(entry, :issue_identifier),
      state: read(entry, :state),
      worker_host: read(entry, :worker_host),
      workspace_path: read(entry, :workspace_path),
      session_id: read(entry, :session_id),
      turn_count: entry |> read(:turn_count, 0) |> normalize_integer(),
      last_event: read(entry, :last_event),
      last_message: read(entry, :last_message),
      pending_approval: read(entry, :pending_approval),
      started_at: read(entry, :started_at),
      last_event_at: read(entry, :last_event_at),
      tokens: normalize_codex_totals(read(entry, :tokens, %{}))
    }
  end

  defp normalize_retry_entry(entry) do
    %{
      issue_id: read(entry, :issue_id),
      issue_identifier: read(entry, :issue_identifier),
      attempt: entry |> read(:attempt, 0) |> normalize_integer(),
      due_at: read(entry, :due_at),
      error: read(entry, :error),
      pending_approval: read(entry, :pending_approval),
      worker_host: read(entry, :worker_host),
      workspace_path: read(entry, :workspace_path)
    }
  end

  defp normalize_codex_totals(payload) do
    %{
      input_tokens: payload |> read(:input_tokens, 0) |> normalize_integer(),
      output_tokens: payload |> read(:output_tokens, 0) |> normalize_integer(),
      total_tokens: payload |> read(:total_tokens, 0) |> normalize_integer(),
      seconds_running: payload |> read(:seconds_running, 0) |> normalize_number()
    }
  end

  defp normalize_error(nil), do: nil

  defp normalize_error(error) when is_map(error) do
    %{
      code: read(error, :code, "snapshot_unavailable"),
      message: read(error, :message, "Snapshot unavailable")
    }
  end

  defp normalize_error(_error), do: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}

  defp read(map, key, default \\ nil)

  defp read(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp read(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp read(_map, _key, default), do: default

  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_list), do: []

  defp normalize_integer(value) when is_integer(value), do: value
  defp normalize_integer(value) when is_float(value), do: trunc(value)
  defp normalize_integer(_value), do: 0

  defp normalize_number(value) when is_number(value), do: value
  defp normalize_number(_value), do: 0

  defp select_repo([], _requested_repo_id), do: nil

  defp select_repo(repos, requested_repo_id) when is_binary(requested_repo_id) do
    Enum.find(repos, &(&1.id == requested_repo_id)) || hd(repos)
  end

  defp select_repo(repos, _requested_repo_id), do: hd(repos)

  defp dashboard_copy(:manager, selected_repo) do
    repo_name =
      case selected_repo do
        %{name: name} -> name
        _ -> "managed repos"
      end

    "Switch between repos, inspect repo-scoped issue activity, and trigger restart controls for #{repo_name}."
  end

  defp dashboard_copy(:runtime, _selected_repo) do
    "Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime."
  end

  defp running_metric_copy(:manager), do: "Active issue sessions in the selected repo runtime."
  defp running_metric_copy(:runtime), do: "Active issue sessions in the current runtime."

  defp retry_metric_copy(:manager), do: "Selected repo issues waiting for the next retry window."
  defp retry_metric_copy(:runtime), do: "Issues waiting for the next retry window."

  defp rate_limit_copy(:manager), do: "Latest upstream rate-limit snapshot for the selected repo runtime."
  defp rate_limit_copy(:runtime), do: "Latest upstream rate-limit snapshot, when available."

  defp running_section_copy(:manager), do: "Active issues, last known agent activity, and token usage for the selected repo."
  defp running_section_copy(:runtime), do: "Active issues, last known agent activity, and token usage."

  defp retry_section_copy(:manager), do: "Selected repo issues waiting for the next retry window."
  defp retry_section_copy(:runtime), do: "Issues waiting for the next retry window."

  defp repo_path(repo_id), do: "/?repo=#{URI.encode(repo_id)}"

  defp issue_details_path(issue_identifier, :manager, selected_repo_id) when is_binary(selected_repo_id) do
    "/api/v1/repos/#{URI.encode(selected_repo_id)}/issues/#{URI.encode(issue_identifier)}"
  end

  defp issue_details_path(issue_identifier, _mode, _selected_repo_id) do
    "/api/v1/#{URI.encode(issue_identifier)}"
  end

  defp repo_button_class(repo, selected_repo_id) do
    base = "repo-pill"
    if repo.id == selected_repo_id, do: "#{base} repo-pill-selected", else: base
  end

  defp repo_health_badge_class(:ok), do: "state-badge state-badge-active"
  defp repo_health_badge_class(:starting), do: "state-badge state-badge-warning"
  defp repo_health_badge_class(:backoff), do: "state-badge state-badge-warning"
  defp repo_health_badge_class(:failing), do: "state-badge state-badge-danger"
  defp repo_health_badge_class(:blocked), do: "state-badge state-badge-danger"
  defp repo_health_badge_class(:stopped), do: "state-badge"
  defp repo_health_badge_class(:disabled), do: "state-badge"
  defp repo_health_badge_class(_health), do: "state-badge"

  defp humanize_repo_health(:ok), do: "Healthy"
  defp humanize_repo_health(:starting), do: "Starting"
  defp humanize_repo_health(:backoff), do: "Restarting"
  defp humanize_repo_health(:failing), do: "Unhealthy"
  defp humanize_repo_health(:blocked), do: "Unavailable"
  defp humanize_repo_health(:stopped), do: "Unavailable"
  defp humanize_repo_health(:disabled), do: "Disabled"
  defp humanize_repo_health(other), do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp repo_health_copy(%{health: :ok}), do: "Runtime reachable and serving repo-scoped dashboard data."
  defp repo_health_copy(%{health: :starting}), do: "Repo runtime is booting after a start or restart request."
  defp repo_health_copy(%{health: :backoff}), do: "Repo runtime is unavailable while the manager waits to restart it."
  defp repo_health_copy(%{health: :failing}), do: "Repo health checks are failing and the runtime may be unstable."
  defp repo_health_copy(%{health: :blocked, blocked_reason: reason}) when is_binary(reason), do: reason
  defp repo_health_copy(%{health: :blocked}), do: "Repo is blocked until its config or prerequisites are fixed."
  defp repo_health_copy(%{health: :stopped}), do: "Repo runtime is not currently reachable."
  defp repo_health_copy(%{health: :disabled}), do: "Repo is disabled in manager config."
  defp repo_health_copy(_repo), do: "Repo status is unknown."

  defp repo_endpoint(%{port: port}) when is_integer(port), do: "127.0.0.1:#{port}"
  defp repo_endpoint(_repo), do: "n/a"

  defp repo_port_label(port) when is_integer(port), do: "port #{port}"
  defp repo_port_label(_port), do: "no port"

  defp repo_last_error(%{last_error: nil}), do: "None"
  defp repo_last_error(%{last_error: error}) when is_binary(error), do: error
  defp repo_last_error(_repo), do: "Unknown"

  defp restart_repo_disabled?(%{enabled: false}), do: true
  defp restart_repo_disabled?(_repo), do: false

  defp put_notice(socket, tone, message) do
    assign(socket, :notice, %{tone: tone, message: message})
  end

  defp notice_card_class(:error), do: "notice-card notice-card-error"
  defp notice_card_class(_tone), do: "notice-card notice-card-info"

  defp repo_restart_error(:repo_disabled), do: "Selected repo is disabled and cannot be restarted."
  defp repo_restart_error(:repo_not_found), do: "Selected repo was not found."
  defp repo_restart_error(:unavailable), do: "Manager is unavailable."

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
