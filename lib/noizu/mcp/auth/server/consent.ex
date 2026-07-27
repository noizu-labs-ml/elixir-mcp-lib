defmodule Noizu.MCP.Auth.Server.Consent do
  @moduledoc """
  Consent policy and the default consent screen.

  ## Why this is mandatory

  Any client can register itself here (that is the point of DCR) and then send a
  user, who is already logged in, to `/oauth/authorize`. Without a consent step
  the authorization server would issue that client a token on the strength of the
  user's session alone — the user's own cookie authorizing a stranger. That is the
  confused-deputy problem the MCP specification calls out, and consent is the fix
  the spec names.

  So: **consent is required for every `:registered` and `:cimd` client**, and
  `consent: [enabled: false]` only affects `:preconfigured` clients, which an
  operator created deliberately.

  Consent is remembered per `{subject, client_id}`, and a request for a scope
  outside what was granted **re-prompts** rather than widening silently.

  ## The form is CSRF-protected

  The token is bound to the login state, so a POST is only accepted from the page
  this server rendered for this flow. Without it, an attacker's page could submit
  the approval on the user's behalf, which is the same hole with an extra step.

  ## Replacing the screen

      consent: [renderer: {MyAppWeb.MCPConsent, :render}]

  The renderer receives `(conn, assigns)` and must return a conn with a response
  sent. `assigns` carries `:client`, `:scope`, `:resource`, `:csrf_token`,
  `:action` (the POST target), `:login_state`, `:subject`. The built-in screen is
  deliberately plain — it works, and it is not trying to be your design system.
  """

  alias Noizu.MCP.Auth.Server.Client
  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.Secret
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Store.Consent, as: Record

  @doc """
  Does this request need a consent screen?

  `:skip` when the client is exempt, or when the subject has already granted a
  superset of the requested scope. `{:prompt, reason}` otherwise, where reason is
  `:no_consent` or `:scope_broadened` — the second is why re-prompting matters:
  a client that quietly asks for more later must be shown again.
  """
  @spec required?(Client.t(), String.t(), [String.t()], Config.t()) ::
          :skip | {:prompt, :no_consent | :scope_broadened}
  def required?(%Client{} = client, subject, scope, %Config{} = config) do
    if Client.requires_consent?(client, config) do
      case granted(client, subject, config) do
        {:ok, %Record{scope: granted}} ->
          if Enum.all?(scope, &(&1 in granted)),
            do: :skip,
            else: {:prompt, :scope_broadened}

        {:error, :not_found} ->
          {:prompt, :no_consent}
      end
    else
      :skip
    end
  end

  @doc "Read a recorded consent."
  @spec granted(Client.t(), String.t(), Config.t()) ::
          {:ok, Record.t()} | {:error, :not_found}
  def granted(%Client{client_id: client_id}, subject, %Config{} = config) do
    {adapter, store_opts} = Config.store(config)

    case adapter.get_consent(subject, client_id, store_opts) do
      {:ok, record} -> {:ok, record}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Record consent, merging with anything granted before.

  The union is stored rather than the latest request, so an agent that legitimately
  narrows its ask on a later call is not re-prompted for scope it already has.
  """
  @spec record(Client.t(), String.t(), [String.t()], String.t() | nil, Config.t()) :: :ok
  def record(%Client{client_id: client_id}, subject, scope, resource, %Config{} = config) do
    {adapter, store_opts} = Config.store(config)

    previous =
      case adapter.get_consent(subject, client_id, store_opts) do
        {:ok, %Record{scope: granted}} -> granted
        _ -> []
      end

    consent = %Record{
      subject: subject,
      client_id: client_id,
      scope: Enum.uniq(previous ++ scope),
      resource: resource,
      granted_at: DateTime.utc_now(),
      expires_at: expiry(config)
    }

    _ = adapter.put_consent(consent, store_opts)
    :ok
  end

  @doc "Withdraw consent, e.g. from an account settings page."
  @spec revoke(String.t(), String.t(), Config.t()) :: :ok
  def revoke(subject, client_id, %Config{} = config) do
    {adapter, store_opts} = Config.store(config)
    _ = adapter.revoke_consent(subject, client_id, store_opts)
    :ok
  end

  @doc """
  A CSRF token bound to a login state. Random per flow, stored alongside the
  state, and compared in constant time.
  """
  @spec csrf_token() :: String.t()
  def csrf_token, do: Store.generate_token()

  @doc """
  Check a submitted CSRF token against the one issued for this flow.

  A flow with no stored token fails: an absent token must never read as "no CSRF
  protection needed".
  """
  @spec valid_csrf?(map(), term()) :: boolean()
  def valid_csrf?(payload, submitted) when is_binary(submitted) do
    case Map.get(payload, "csrf_token") do
      expected when is_binary(expected) -> Secret.equal?(expected, submitted)
      _ -> false
    end
  end

  def valid_csrf?(_payload, _submitted), do: false

  @doc """
  The built-in consent screen, as an HTML string.

  Everything interpolated is escaped. Two of these values are attacker-chosen —
  a self-registered client's `client_name` and the scope strings — so this is the
  one place in the AS where an escaping slip becomes stored XSS on the host's own
  origin.
  """
  @spec render_html(map()) :: String.t()
  def render_html(assigns) do
    client = assigns.client
    name = escape(client.client_name || client.client_id)

    scopes =
      Enum.map_join(assigns.scope, "", fn scope -> "<li><code>#{escape(scope)}</code></li>" end)

    resource =
      case assigns[:resource] do
        nil ->
          ""

        resource ->
          ~s(<p class="resource">Access is limited to <code>#{escape(resource)}</code>.</p>)
      end

    kind_note =
      case client.client_id_kind do
        :registered ->
          ~s(<p class="warn">This application registered itself. Approve it only if you started this.</p>)

        :cimd ->
          ~s(<p class="warn">Identified by <code>#{escape(client.client_id)}</code>. Approve it only if you recognize that address.</p>)

        _ ->
          ""
      end

    """
    <!DOCTYPE html>
    <html lang="en"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Authorize #{name}</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 16px/1.5 system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem; }
      h1 { font-size: 1.3rem; }
      ul { padding-left: 1.2rem; }
      code { background: rgba(127,127,127,.18); padding: .1em .35em; border-radius: 3px; }
      .warn { background: rgba(200,140,0,.14); padding: .75rem; border-radius: 6px; }
      .actions { display: flex; gap: .75rem; margin-top: 2rem; }
      button { font: inherit; padding: .6rem 1.2rem; border-radius: 6px; border: 1px solid transparent; cursor: pointer; }
      button.approve { background: #2563eb; color: #fff; }
      button.deny { background: transparent; border-color: currentColor; }
    </style>
    </head><body>
    <h1>#{name} wants access to your account</h1>
    #{kind_note}
    <p>It is asking for:</p>
    <ul>#{scopes}</ul>
    #{resource}
    <form method="post" action="#{escape(assigns.action)}">
      <input type="hidden" name="login_state" value="#{escape(assigns.login_state)}">
      <input type="hidden" name="csrf_token" value="#{escape(assigns.csrf_token)}">
      <div class="actions">
        <button class="approve" type="submit" name="decision" value="approve">Approve</button>
        <button class="deny" type="submit" name="decision" value="deny">Deny</button>
      </div>
    </form>
    </body></html>
    """
  end

  defp expiry(%Config{consent: consent}) do
    case Keyword.get(consent, :ttl) do
      nil -> nil
      ttl -> DateTime.add(DateTime.utc_now(), ttl, :second)
    end
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
