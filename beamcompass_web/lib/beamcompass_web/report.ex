defmodule BeamCompassWeb.Report do
  @moduledoc "Self-contained static HTML explorer for source-grounded snapshots."

  alias BeamCompass.Model.Snapshot

  @spec render(Snapshot.t()) :: binary()
  def render(%Snapshot{} = snapshot) do
    section_html =
      [:behavior, :effects, :state]
      |> Enum.map_join("\n", fn lens ->
        {:ok, view} = BeamCompass.project(snapshot, lens: lens, budget: 500)
        render_lens(view)
      end)

    issues_html =
      snapshot.issues
      |> Enum.map_join("\n", fn issue ->
        "<li>#{escape(issue["path"])}: #{escape(issue["reason"])}</li>"
      end)

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>BeamCompass — Operational Atlas</title>
      <style>
        :root {color-scheme: dark; font-family: system-ui, sans-serif;}
        body {max-width: 1120px; margin: 2rem auto; padding: 0 1.2rem;
              background: #101925; color: #e8eff7; line-height: 1.6;}
        h1 {font-size: 2.1rem;} h2 {margin-top: 2.4rem;}
        .hint {color: #a2b5cb;} .cards {display: grid;
          grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 1rem;}
        article {background: #19293b; border: 1px solid #344a60;
          padding: 1rem; border-radius: 0.8rem; overflow-wrap: anywhere;}
        article p {color: #c4d3e1;} code {font-size: 0.85rem; color: #b7d6ff;}
        .tag {font-size: 0.75rem; background: #304b66; padding: .15rem .4rem;
          border-radius: .25rem;} .warn {color: #ffdb9a;}
      </style>
    </head>
    <body>
      <header><h1>BeamCompass</h1>
        <p class="hint">Evidence-backed, source-only operational inventory.</p>
        <p><code>Snapshot #{escape(snapshot.id)}</code></p>
        <p class="warn">A source occurrence is not proof of runtime reachability.
        Capsules are provisional and local to handler clauses.</p>
      </header>
      #{section_html}
      <section><h2>Scanner issues (#{length(snapshot.issues)})</h2><ul>#{issues_html}</ul></section>
    </body>
    </html>
    """
  end

  defp render_lens(view) do
    cards =
      view["nodes"]
      |> Enum.map_join("\n", fn node ->
        """
        <article>
          <span class="tag">#{escape(node["kind"])}</span>
          <h3>#{escape(node["title"])}</h3>
          <p>#{escape(node["subtitle"])}</p>
          <code>Evidence: #{escape(node["source_fact_id"])}</code>
        </article>
        """
      end)

    """
    <section>
      <h2>#{escape(String.capitalize(view["lens"]))} lens</h2>
      <p class="hint">#{length(view["nodes"])} visible records;
      #{view["unresolved_count"]} unresolved source relationships overall.
      No inferred runtime interactions are asserted.</p>
      <div class="cards">#{cards}</div>
    </section>
    """
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
