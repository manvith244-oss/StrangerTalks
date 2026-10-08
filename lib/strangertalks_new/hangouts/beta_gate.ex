defmodule StrangertalksNew.Hangouts.BetaGate do
  @moduledoc """
  Single fail-closed runtime authority for public Hangouts admission.

  Only the literal boolean true enables Hangouts. Unset, malformed, nil and all
  other values disable it. This module is not a replacement for participant,
  membership or safety authorization on the enabled path.
  """

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:strangertalks_new, :hangouts_public_beta_enabled, false) === true
  end

  @spec require_enabled() :: :ok | {:error, :feature_unavailable}
  def require_enabled do
    if enabled?(), do: :ok, else: {:error, :feature_unavailable}
  end
end
