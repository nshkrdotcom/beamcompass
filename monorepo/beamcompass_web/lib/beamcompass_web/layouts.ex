defmodule BeamCompassWeb.Layouts do
  @moduledoc "Minimal accessible root HTML; no external scripts or analytics."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <meta name="color-scheme" content="dark" />
        <title>BeamCompass · Source navigator</title>
        <link rel="stylesheet" href="/assets/navigator.css" />
        <script defer src="/assets/app.js"></script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
