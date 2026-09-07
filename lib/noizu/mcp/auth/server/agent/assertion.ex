defmodule Noizu.MCP.Auth.Server.Agent.Assertion do
  @moduledoc """
  The signed proof an agent presents to trade an anonymous session for an
  authenticated one.

  Wire format is an ordinary **RFC 7515 compact JWS** with `alg: "EdDSA"` over
  Ed25519 (RFC 8037), used as an RFC 7523 `jwt-bearer` client assertion. That
  choice is the point: an MCP client that already speaks OAuth needs no bespoke
  code to talk to this server, and the format is reviewable against published
  specs rather than against this module's opinions.

      {"alg":"EdDSA","typ":"JWT","kid":"<thumbprint>"}
      {"iss":"<account_id>","sub":"<account_id>","aud":"<token endpoint>",
       "hdl":"<handle>","iat":...,"exp":...,"jti":"<uuid>",
       "sid":"<session id>","nonce":"<session nonce>"}

  ## Why verification is hand-rolled

  Signature checking is `:crypto.verify(:eddsa, ...)` against a 32-byte key, and
  the JWS is split and decoded here rather than handed to a general JOSE parser.
  A general parser's job is to honour whatever the token asks for; this module's
  job is to refuse everything except exactly one shape. Concretely, that closes:

    * **`alg` confusion** — `"none"`, `HS256` (where the "key" would be our own
      public key), and every other algorithm are rejected before any key is
      loaded, not after.
    * **Key injection** — a `jwk`, `jku` or `x5u` header lets a token nominate the
      key that verifies it, which verifies every token. Their mere presence is
      fatal here; they are never consulted.
    * **Unbounded input** — the assertion is length-capped before any base64 or
      JSON decoding runs.

  ## Why `nonce` exists alongside `iat`

  A timestamp alone bounds a replay window; it does not close it. Anything that
  observes the request inside the clock-skew window — a reverse proxy, an access
  log, a sidecar, a retried HTTP client — can send the identical bytes again and
  be issued a second token. Because the agent has already fetched an anonymous
  session token before it signs (it needs one to reach this endpoint), binding the
  assertion to that session's server-issued `nonce` costs no extra round trip and
  makes a captured assertion worthless the moment the session is consumed. `jti`
  is the second line: it catches a replay aimed at a session that is somehow still
  live.
  """

  @typedoc "A parsed but **not yet verified** assertion. Do not trust the claims."
  @type t :: %__MODULE__{
          header: map(),
          claims: map(),
          kid: String.t(),
          signing_input: binary(),
          signature: binary()
        }

  defstruct header: %{}, claims: %{}, kid: nil, signing_input: nil, signature: nil

  @type reason ::
          :malformed
          | :too_large
          | :unsupported_alg
          | :key_injection
          | :missing_kid
          | :bad_signature
          | :missing_claim
          | :bad_claim
          | :bad_audience
          | :bad_subject
          | :bad_handle
          | :expired
          | :not_yet_valid
          | :lifetime_too_long

  # Generous next to a legitimate assertion (a few hundred bytes) and small enough
  # that a flood costs the decoder nothing.
  @max_bytes 8_192
  @sig_bytes 64
  # Every assertion needs these. `sid`/`nonce` are additionally required on the
  # authentication path via `:require` — a key-management proof has no session to
  # bind to, because the caller already holds an authenticated token.
  @base_required ~w(iss sub aud iat exp jti)

  @doc """
  Split and decode a compact JWS without checking anything that needs a key.

  Parsing must come first because `kid` is what tells the caller *which* key to
  load. Everything this returns is attacker-controlled until `verify/3` succeeds.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, reason()}
  def parse(assertion) when is_binary(assertion) do
    cond do
      byte_size(assertion) > @max_bytes ->
        {:error, :too_large}

      true ->
        with [h, p, s] <- String.split(assertion, ".", parts: 4),
             {:ok, header} <- decode_json(h),
             {:ok, claims} <- decode_json(p),
             {:ok, signature} <- decode_segment(s),
             :ok <- check_header(header),
             true <- byte_size(signature) == @sig_bytes or {:error, :bad_signature} do
          {:ok,
           %__MODULE__{
             header: header,
             claims: claims,
             kid: Map.get(header, "kid"),
             signing_input: h <> "." <> p,
             signature: signature
           }}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :malformed}
        end
    end
  end

  def parse(_), do: {:error, :malformed}

  @doc """
  Verify signature and every claim that can be checked without touching a store.

  Required opts:

    * `:public_key` — the 32 raw bytes for `kid`, already looked up by the caller
    * `:audience` — this server's token endpoint URL
    * `:account_id` — the account the caller resolved `kid` to
    * `:handle` — that account's handle

  Optional:

    * `:now` — `DateTime`, defaults to now
    * `:skew` — seconds of tolerated clock difference, default 60
    * `:max_age` — largest permitted `exp - iat`, default 300
    * `:require` — extra claim names that must be present and non-empty. The
      authentication path passes `["sid", "nonce"]`; a key-management proof passes
      nothing, having no session to bind to.
    * `:expect` — a map of claim ⇒ exact required value. Used to bind a proof to
      one operation (`"op" => "add_key"`) and one subject key
      (`"jkt" => <thumbprint>`), so a signature collected for one purpose cannot
      be presented for another.

  Store-dependent checks — `jti` never seen, `sid`/`nonce` matching a live
  session, account status — deliberately stay with the caller. Mixing I/O in here
  would make this module untestable without a store, which is the last thing you
  want for the code that decides whether a signature counts.
  """
  @spec verify(t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def verify(%__MODULE__{} = assertion, opts) do
    public_key = Keyword.fetch!(opts, :public_key)
    now = opts |> Keyword.get(:now) |> then(&(&1 || DateTime.utc_now())) |> DateTime.to_unix()
    skew = Keyword.get(opts, :skew, 60)
    max_age = Keyword.get(opts, :max_age, 300)

    with :ok <- check_signature(assertion, public_key),
         :ok <- check_required(assertion.claims, Keyword.get(opts, :require, [])),
         :ok <- check_expected(assertion.claims, Keyword.get(opts, :expect, %{})),
         :ok <- check_audience(assertion.claims, Keyword.fetch!(opts, :audience)),
         :ok <- check_subject(assertion.claims, Keyword.fetch!(opts, :account_id)),
         :ok <- check_handle(assertion.claims, Keyword.fetch!(opts, :handle)),
         :ok <- check_time(assertion.claims, now, skew, max_age) do
      {:ok, assertion.claims}
    end
  end

  @doc """
  Sign an assertion. For tests and for client SDKs — a server never calls this.

  `private_key` is the 64-byte Ed25519 secret (seed plus public half) as produced
  by `:crypto.generate_key(:eddsa, :ed25519)`.
  """
  @spec sign(map(), binary(), String.t()) :: String.t()
  def sign(claims, private_key, kid) do
    header = %{"alg" => "EdDSA", "typ" => "JWT", "kid" => kid}
    h = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    p = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    input = h <> "." <> p
    sig = :crypto.sign(:eddsa, :none, input, [private_key, :ed25519])
    input <> "." <> Base.url_encode64(sig, padding: false)
  end

  # --- internals -----------------------------------------------------------

  defp check_signature(%__MODULE__{signing_input: input, signature: sig}, public_key)
       when byte_size(public_key) == 32 do
    if :crypto.verify(:eddsa, :none, input, sig, [public_key, :ed25519]),
      do: :ok,
      else: {:error, :bad_signature}
  rescue
    # A key that survived `Key.decode/1` should never land here, but a verify that
    # raises would surface as a 500 on an unauthenticated endpoint — a free way to
    # tell attacker-shaped input from ordinary input. Fail closed and quietly.
    _ -> {:error, :bad_signature}
  end

  defp check_signature(_assertion, _public_key), do: {:error, :bad_signature}

  # `decode_json/1` guarantees a map, so there is no non-map clause to write.
  defp check_header(header) when is_map(header) do
    cond do
      Map.has_key?(header, "jwk") or Map.has_key?(header, "jku") or
          Map.has_key?(header, "x5u") or Map.has_key?(header, "x5c") ->
        {:error, :key_injection}

      Map.get(header, "alg") != "EdDSA" ->
        {:error, :unsupported_alg}

      not is_binary(Map.get(header, "kid")) or Map.get(header, "kid") == "" ->
        {:error, :missing_kid}

      true ->
        :ok
    end
  end

  defp check_required(claims, extra) when is_map(claims) do
    if Enum.all?(@base_required ++ extra, &present?(Map.get(claims, &1))),
      do: :ok,
      else: {:error, :missing_claim}
  end

  defp check_required(_claims, _extra), do: {:error, :malformed}

  defp check_expected(claims, expected) do
    if Enum.all?(expected, fn {claim, value} -> Map.get(claims, claim) == value end),
      do: :ok,
      else: {:error, :bad_claim}
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value) when is_integer(value), do: true
  # `aud` is permitted to be an array (RFC 7519 §4.1.3) and `check_audience/2`
  # handles that shape — so presence must accept it too, or an array audience is
  # rejected as a missing claim before the audience check ever runs.
  defp present?(value) when is_list(value), do: value != []
  defp present?(_), do: false

  # `aud` may be a string or an array (RFC 7519 §4.1.3).
  defp check_audience(claims, expected) do
    case Map.get(claims, "aud") do
      ^expected -> :ok
      list when is_list(list) -> if expected in list, do: :ok, else: {:error, :bad_audience}
      _ -> {:error, :bad_audience}
    end
  end

  defp check_subject(claims, account_id) do
    if Map.get(claims, "iss") == account_id and Map.get(claims, "sub") == account_id,
      do: :ok,
      else: {:error, :bad_subject}
  end

  defp check_handle(claims, handle) do
    if Map.get(claims, "hdl") == handle, do: :ok, else: {:error, :bad_handle}
  end

  defp check_time(claims, now, skew, max_age) do
    iat = Map.get(claims, "iat")
    exp = Map.get(claims, "exp")

    cond do
      not is_integer(iat) or not is_integer(exp) -> {:error, :missing_claim}
      iat - skew > now -> {:error, :not_yet_valid}
      exp + skew < now -> {:error, :expired}
      exp <= iat -> {:error, :lifetime_too_long}
      exp - iat > max_age -> {:error, :lifetime_too_long}
      true -> :ok
    end
  end

  defp decode_segment(segment) do
    case Base.url_decode64(segment, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :malformed}
    end
  end

  defp decode_json(segment) do
    with {:ok, raw} <- decode_segment(segment),
         {:ok, map} when is_map(map) <- Jason.decode(raw) do
      {:ok, map}
    else
      _ -> {:error, :malformed}
    end
  end
end
