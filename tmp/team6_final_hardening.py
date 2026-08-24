from pathlib import Path
from textwrap import dedent


def D(value: str) -> str:
    return dedent(value).strip("\n")


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f"{label}: start marker not found: {start!r}")
    b = text.find(end, a + len(start))
    if b < 0:
        raise RuntimeError(f"{label}: end marker not found: {end!r}")
    return text[:a] + replacement.rstrip() + "\n\n" + text[b:]


authority_path = Path("test/strangertalks_new/team6_media_authority_test.exs")
authority = authority_path.read_text()
authority = authority.replace(
    '  endtest "sibling tab cannot mutate effect or reaction state"',
    '  end\n\n  test "sibling tab cannot mutate effect or reaction state"',
    1,
)

if 'test "authoritative endpoint cannot request deferred screen share"' not in authority:
    addition = D('''
      test "authoritative endpoint cannot request deferred screen share" do
        %{conv: conv, p1: p1, p1_owner: owner, attempt: attempt} = active_call()

        assert {:error, :unsupported_media_type} =
                 ConversationServer.request_call_media(
                   conv.conversation_id,
                   p1,
                   owner,
                   "p1-owner",
                   attempt,
                   :screen_share,
                   %{}
                 )
      end
    ''')
    pos = authority.rfind("\nend")
    if pos < 0:
        raise RuntimeError("authority test module end not found")
    authority = authority[:pos] + "\n\n" + addition + authority[pos:]
authority_path.write_text(authority)

app_path = Path("priv/static/assets/app.js")
app = app_path.read_text()
handler = D(r'''
  $("#btn-call-screen-share")?.addEventListener("click", async () => {
    await app.liveCall?.requestMediaUpgrade("screen_share")
  })
''')
if handler in app:
    app = app.replace(handler, "", 1)
app_path.write_text(app)

index_path = Path("priv/static/index.html")
index = index_path.read_text()
index = index.replace('<button id="btn-call-screen-share" type="button">Share Screen</button>', "", 1)
index_path.write_text(index)

server_path = Path("lib/strangertalks_new/conversation_lifecycle/conversation_server.ex")
server = server_path.read_text()
server = replace_between(
    server,
    "  def request_call_media(",
    "  def respond_call_media(",
    D('''
      def request_call_media(
            conversation_id,
            participant_id,
            channel_pid,
            session_id,
            call_attempt_id,
            request_type,
            proposal
          ) do
        if request_type in [:video_upgrade, "video_upgrade"] do
          admitted_call(
            conversation_id,
            {:request_call_media, participant_id, channel_pid, session_id, call_attempt_id,
             request_type, proposal},
            @mailbox_soft_limit,
            :conversation_busy
          )
        else
          {:error, :unsupported_media_type}
        end
      end
    '''),
    "Screen Share public server rejection",
)
server_path.write_text(server)

# The direct remediation script is temporary Python that emits Elixir source.
# Repair Python string escaping so Elixir default arguments retain two backslashes.
c11_path = Path("lib/strangertalks_new/c11_policy.ex")
c11 = c11_path.read_text()
c11 = c11.replace("now \\ nil) do", "now \\\\ nil) do")
c11_path.write_text(c11)

runtime_path = Path("config/runtime.exs")
runtime = runtime_path.read_text()
turn_start = runtime.find('turn_oracle_urls = System.get_env("TURN_ORACLE_URLS"')
if turn_start >= 0:
    prod_marker = "\n\nif config_env() == :prod do"
    turn_end = runtime.find(prod_marker, turn_start)
    if turn_end < 0:
        raise RuntimeError("runtime TURN block end not found")
    block = runtime[turn_start:turn_end].strip("\n")
    if not block.startswith("if config_env() == :prod do"):
        indented = "\n".join(("  " + line) if line else "" for line in block.splitlines())
        runtime = runtime[:turn_start] + "if config_env() == :prod do\n" + indented + "\nend" + runtime[turn_end:]
runtime_path.write_text(runtime)

privacy_path = Path("test/js/team6_media_privacy_test.mjs")
privacy = privacy_path.read_text()
if 'test("active-call V1 UI has no Screen Share action"' not in privacy:
    privacy += "\n" + D(r'''
      test("active-call V1 UI has no Screen Share action", () => {
        const html = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
        assert.doesNotMatch(html, /btn-call-screen-share|Share Screen/i)
      })
    ''') + "\n"
privacy_path.write_text(privacy)

turn_path = Path("test/strangertalks_new/team6_turn_provider_test.exs")
turn = turn_path.read_text()
if 'test "malformed provider configuration fails closed"' not in turn:
    addition = D('''
      test "malformed provider configuration fails closed" do
        state =
          C11Policy.init_state(
            quotas_verified: true,
            primary_available: true,
            fallback_available: false,
            credential_ttl_seconds: 300,
            provider_credentials: %{
              oracle: %{strategy: :coturn_rest, urls: ["stun:invalid.example:3478"], shared_secret: ""}
            }
          )

        assert {:error, :provider_not_configured, _} =
                 C11Policy.admit_and_reserve(state, "conversation", "attempt-malformed")
      end

      test "provider secret configuration is server-only" do
        app = File.read!("priv/static/assets/app.js")
        live = File.read!("priv/static/assets/live_call.mjs")
        browser_source = app <> live
        refute browser_source =~ "TURN_ORACLE_SHARED_SECRET"
        refute browser_source =~ "CLOUDFLARE_TURN_API_TOKEN"
        refute browser_source =~ "team6-test-token"
        refute browser_source =~ "team6-test-only-coturn-secret"
      end
    ''')
    pos = turn.rfind("\nend")
    if pos < 0:
        raise RuntimeError("TURN provider test module end not found")
    turn = turn[:pos] + "\n\n" + addition + turn[pos:]
turn_path.write_text(turn)

print("TEAM6_FINAL_HARDENING_APPLIED")
