defmodule StrangertalksNew.TurnCredentialTestClient do
  @moduledoc false
  def generate_ice_servers(_config, _ttl) do
    {:ok,
     [
       %{
         "urls" => [
           "stun:stun.cloudflare.com:3478",
           "turn:turn.cloudflare.com:3478?transport=udp",
           "turns:turn.cloudflare.com:5349?transport=tcp"
         ],
         "username" => "team6-test-user",
         "credential" => "team6-test-credential"
       }
     ]}
  end
end
