defmodule BeamCompassWeb.NavigatorLive do
  @moduledoc """
  LiveView shell: source meaning, exact selection and bounded receipts always
  come from BeamCompass.Analysis.Navigator in the independent core app.
  Browser JavaScript renders geometry and assists keyboard focus only.
  """
  use Phoenix.LiveView

  alias BeamCompass.Analysis.Navigator
  alias BeamCompassWeb.NavigatorSource

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    case NavigatorSource.load() do
      {:ok, snapshot} ->
        {:ok, assign(socket, snapshot: snapshot, revisions: NavigatorSource.revisions(snapshot), view: nil, diagnostic: nil)}

      {:error, reason} ->
        {:ok, assign(socket, snapshot: nil, revisions: [], view: nil, diagnostic: Atom.to_string(reason))}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, uri, %{assigns: %{snapshot: snapshot}} = socket)
      when is_map(snapshot) do
    query = URI.parse(uri).query || ""
    # The selection is evaluated by core; the catalog only locates an exact
    # exported snapshot. On a missing revision, core generates the unavailable
    # diagnostic from the base snapshot without silently rebinding anything.
    source =
      case NavigatorSource.select(snapshot, params) do
        {:ok, revision} -> revision
        {:error, :revision_unavailable} -> snapshot
      end

    case Navigator.from_query(source, query) do
      {:ok, view} -> {:noreply, assign(socket, view: view, diagnostic: nil)}
      {:error, reason} -> {:noreply, assign(socket, view: nil, diagnostic: inspect(reason))}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main id="navigator-main" class="navigator-layout">
      <header class="topbar">
        <div>
          <a href="/navigator" class="brand" aria-label="BeamCompass navigator home">◈ BEAMCOMPASS</a>
          <span class="eyebrow">SOURCE-ONLY BEHAVIORAL NAVIGATOR</span>
        </div>
        <p class="source-warning">Possible source relationships · not observed runtime execution</p>
      </header>

      <%= if @diagnostic do %>
        <section role="alert" id="navigator-error" class="diagnostic">
          <h1>Snapshot or navigation unavailable</h1>
          <p>{@diagnostic}</p>
          <p>No other revision or similarly named target was substituted.</p>
        </section>
      <% else %>
        <%= if @view && @view["status"] == "unavailable" do %>
          <section role="alert" class="diagnostic" id="unavailable-target">
            <h1>Unavailable pinned target</h1>
            <p>{@view["diagnostics"] |> hd() |> Map.fetch!("code")}</p>
            <p>No nearest-name fallback or cross-snapshot rebinding was attempted.</p>
          </section>
        <% else %>
          <%= if @view do %>
            <div class="identity-strip">
              <span>PROJECT <code>{@view["project_id"]}</code></span>
              <span>SNAPSHOT <code>{@view["snapshot_id"]}</code></span>
            </div>
            <%= if length(@revisions) > 1 do %>
              <nav aria-label="Archived source revisions" class="revision-nav">
                <strong>Exported revisions</strong>
                <%= for revision <- @revisions do %>
                  <.link patch={revision_href(@view, revision)}
                    aria-current={if(@view["snapshot_id"] == revision["snapshot_id"], do: "page", else: false)}>
                    {String.slice(revision["snapshot_id"], 0, 12)}
                  </.link>
                <% end %>
              </nav>
              <p class="revision-note">Opening a revision resets the selection; it never remaps source objects by label.</p>
            <% end %>
            <nav aria-label="Source-grounded questions" class="question-nav">
              <h2>Explore source questions</h2>
              <ul>
                <%= for question <- @view["questions"] do %>
                  <li><.link patch={question["href"]}>{question["title"]}</.link></li>
                <% end %>
              </ul>
              <p>Questions describe possible source paths, not observed execution.</p>
            </nav>
            <nav aria-label="Source view lenses" class="lens-nav">
              <%= for lens <- ~w(behavior effects state failure) do %>
                <.link patch={@view["navigation"]["lenses"][lens]} aria-current={if(@view["lens"] == lens, do: "page", else: false)}>
                  {String.capitalize(lens)}
                </.link>
              <% end %>
            </nav>
            <div class="toolbar" aria-label="Semantic zoom controls">
              <h1>Source view · {@view["lens"]}</h1>
              <span>Visible record budget: <strong>{@view["budget"]}</strong></span>
              <.link patch={@view["navigation"]["zoom_out"]} aria-label="Decrease semantic budget">− Zoom out</.link>
              <.link patch={@view["navigation"]["zoom_in"]} aria-label="Increase semantic budget">+ Zoom in</.link>
            </div>
            <div class="workbench">
              <section aria-labelledby="stage-heading" class="stage-region">
                <h2 id="stage-heading">Evidence stage</h2>
                <div id="semantic-stage" phx-hook="SemanticStage"
                     data-view={encode_view(@view)}></div>
                <noscript>
                  <ul aria-label="Source records without JavaScript">
                    <%= for node <- @view["stage"]["nodes"] do %>
                      <li><.link patch={node["href"]}>{node["label"]}</.link></li>
                    <% end %>
                  </ul>
                </noscript>
              </section>
              <aside id="source-drawer" aria-label="Source and evidence details" tabindex="-1">
                <h2>Source &amp; evidence</h2>
                <%= if @view["drawer"] do %>
                  <h3>{@view["drawer"]["label"]}</h3>
                  <p>Exact object: <code>{@view["drawer"]["reference"]["object_id"]}</code></p>
                  <%= for evidence <- @view["drawer"]["evidence"] do %>
                    <article class="evidence-row">
                      <h4><.link patch={evidence["href"]} aria-label={"Inspect evidence " <> evidence["id"]}>{evidence["id"]}</.link></h4>
                      <p>{evidence["mode"]} · {evidence["provider_id"]}</p>
                      <p><code>{evidence["anchor"]["path"]}:{evidence["anchor"]["start_line"]}:{evidence["anchor"]["start_column"]}</code></p>
                      <p>Source digest: <code>{evidence["anchor"]["source_sha256"]}</code> · end position unavailable</p>
                      <p>{evidence["basis"]}</p>
                      <%= if (evidence["lineage"] || []) != [] do %>
                        <p>Source evidence lineage</p>
                        <ul>
                          <%= for parent <- evidence["lineage"] || [] do %>
                            <li><.link patch={parent["href"]}>{parent["id"]}</.link></li>
                          <% end %>
                        </ul>
                      <% end %>
                    </article>
                  <% end %>
                  <h4>Explicit related source records</h4>
                  <ul>
                    <%= for related <- @view["drawer"]["related"] do %>
                      <li>
                        <%= if related["href"] do %>
                          <.link patch={related["href"]}>{related["role"]}: {related["kind"]} ({related["resolution"]})</.link>
                        <% else %>
                          {related["role"]}: unresolved — no endpoint available
                        <% end %>
                      </li>
                    <% end %>
                  </ul>
                <% else %>
                  <p>Select an exact source record to open its evidence and provenance.</p>
                <% end %>
              </aside>
            </div>
            <section id="projection-receipts" class="receipts" aria-labelledby="receipt-heading">
              <h2 id="receipt-heading">Preservation, omissions &amp; uncertainty</h2>
              <p id="preservation-status">{@view["projection"]["receipt"]["status"]} · {@view["projection"]["receipt"]["completeness"]}</p>
              <p>Visible: {@view["projection"]["receipt"]["counts"]["visible"]} · Omitted: {@view["projection"]["receipt"]["counts"]["omitted"]} · Collapsed: {@view["projection"]["receipt"]["counts"]["collapsed"]} · Unknown: {@view["projection"]["receipt"]["counts"]["unknown"]}</p>
              <details><summary>Omitted source records</summary><ul>
                <%= for entry <- @view["projection"]["omitted"] do %>
                  <li>{entry["reference"]["object_kind"]}:{entry["reference"]["object_id"]} — {entry["reason"]}</li>
                <% end %>
              </ul></details>
              <details><summary>Unresolved source relations</summary><ul>
                <%= for entry <- @view["projection"]["unknown"] do %>
                  <li>{entry["reference"]["object_id"]} — {entry["reason"]}</li>
                <% end %>
              </ul></details>
              <details><summary>Collapsed and unsatisfied witnesses</summary><ul>
                <%= for entry <- @view["projection"]["collapsed"] do %>
                  <li>{entry["reference"]["object_id"]} — {entry["reason"]}</li>
                <% end %>
                <%= for entry <- @view["projection"]["receipt"]["unsatisfied"] do %>
                  <li>Not preserved: {entry["object_kind"]}:{entry["object_id"]}</li>
                <% end %>
              </ul></details>
            </section>
            <footer>Source anchors are start-only where end spans are unavailable; no negative effect proof, message ordering or runtime causality is asserted.</footer>
          <% end %>
        <% end %>
      <% end %>
    </main>
    """
  end

  defp encode_view(view), do: view |> BeamCompass.Json.encode() |> Base.url_encode64(padding: false)

  defp revision_href(view, revision) do
    "?" <>
      Navigator.query_string(%{
        "project" => view["project_id"],
        "snapshot" => revision["snapshot_id"],
        "lens" => view["lens"],
        "budget" => Integer.to_string(view["budget"])
      })
  end
end
