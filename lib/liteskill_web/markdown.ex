defmodule LiteskillWeb.Markdown do
  @moduledoc """
  Converts Markdown content to safe HTML for rendering in the chat UI.
  """

  @mdex_opts [
    extension: [
      table: true,
      strikethrough: true,
      autolink: true,
      tasklist: true,
      footnotes: true
    ],
    render: [
      github_pre_lang: true
    ],
    syntax_highlight: [
      formatter: {:html_inline, theme: "onedark"}
    ]
  ]

  @uuid_re ~r/\[uuid:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/

  @doc """
  Renders a complete markdown string to an HTML-safe Phoenix.HTML struct.
  """
  def render(nil), do: {:safe, ""}
  def render(""), do: {:safe, ""}

  def render(markdown) when is_binary(markdown) do
    {:safe, markdown |> MDEx.to_html!(@mdex_opts) |> replace_citations()}
  end

  @doc """
  Renders a streaming (potentially incomplete) markdown fragment.
  Uses mdex's streaming mode which auto-closes unclosed nodes.
  """
  def render_streaming(nil), do: {:safe, ""}
  def render_streaming(""), do: {:safe, ""}

  def render_streaming(markdown) when is_binary(markdown) do
    html =
      MDEx.new(Keyword.merge(@mdex_opts, streaming: true, markdown: markdown))
      |> MDEx.to_html!()

    {:safe, replace_citations(html)}
  end

  defp replace_citations(html) do
    {result, _n} =
      Regex.scan(@uuid_re, html)
      |> Enum.reduce({html, 1}, fn [full_match, uuid], {acc, n} ->
        replacement =
          ~s(<button class="rag-cite" phx-click="show_source" phx-value-doc-id="#{uuid}">#{n}</button>)

        {String.replace(acc, full_match, replacement, global: false), n + 1}
      end)

    result
  end
end
