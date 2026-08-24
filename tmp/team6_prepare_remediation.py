from pathlib import Path

path = Path("tmp/team6_direct_remediate.py")
text = path.read_text()

# Replace the whitespace-sensitive helper insertion with a function-boundary insertion.
start = text.index('if "canTransmitOutgoingAudio()" not in live:')
end = text.index('\nlive = replace_between(', start)
replacement = r"""if "canTransmitOutgoingAudio()" not in live:
    helpers = D('''
      notifyStateChange() {
        this.onStateChange(this.getState())
      }

      canTransmitOutgoingAudio() {
        return Boolean(
          this.callAttemptId &&
          this.status === CALL_STATUS.ACTIVE &&
          !this.selfMuted
        )
      }

      applyOutgoingAudioGate() {
        const enabled = this.canTransmitOutgoingAudio()
        if (this.rawAudioTrack) this.rawAudioTrack.enabled = enabled
        if (this.processedAudioTrack) this.processedAudioTrack.enabled = enabled
        if (this.localStream?.getAudioTracks) {
          for (const track of this.localStream.getAudioTracks()) track.enabled = enabled
        }
      }

      mediaAttemptIsCurrent(callAttemptId, mediaGeneration, peerConnection = this.peerConnection) {
        return Boolean(
          callAttemptId &&
          this.callAttemptId === callAttemptId &&
          this.mediaGeneration === mediaGeneration &&
          [CALL_STATUS.CONNECTING, CALL_STATUS.ACTIVE].includes(this.status) &&
          (!peerConnection || this.peerConnection === peerConnection)
        )
      }
    ''')
    live = replace_between(
        live,
        '  notifyStateChange() {',
        '  // --- Channel Event Handlers ---',
        helpers,
        "insert media authority helpers"
    )
"""
text = text[:start] + replacement + text[end:]

# Replace the temporary Voice Expression edit plan with a function-scoped transformation.
effect_plan_start = text.index('# Preserve the existing effect graph')
init_plan_start = text.index("live = replace_between(\n    live,\n    '  async initializeWebRTC", effect_plan_start)
effect_plan = r'''# Voice Expression transmission authority is applied only to the selected sender track.
effect_start = live.index('  async setVoiceExpression(preset = "plain") {')
effect_end = live.index('  cleanupEffectGraph() {', effect_start)
effect_source = live[effect_start:effect_end]

plain_old = 'this.rawAudioTrack.enabled = !this.selfMuted'
if effect_source.count(plain_old) != 1:
    raise RuntimeError(f"plain effect gate: expected one match, found {effect_source.count(plain_old)}")
effect_source = effect_source.replace(plain_old, 'this.rawAudioTrack.enabled = this.canTransmitOutgoingAudio()', 1)

processed_old = 'this.processedAudioTrack.enabled = !this.selfMuted'
if effect_source.count(processed_old) != 1:
    raise RuntimeError(f"processed effect gate: expected one match, found {effect_source.count(processed_old)}")
effect_source = effect_source.replace(processed_old, 'this.processedAudioTrack.enabled = this.canTransmitOutgoingAudio()', 1)

live = live[:effect_start] + effect_source + live[effect_end:]

'''
text = text[:effect_plan_start] + effect_plan + text[init_plan_start:]

# Replace the indentation-sensitive Screen Share client edit plan with a complete public-method replacement.
screen_plan_start = text.index('# Screen Share is frozen OUT OF V1.')
screen_plan_end = text.index('live_path.write_text(live)', screen_plan_start)
screen_plan = r"""# Screen Share is frozen OUT OF V1. Only Video upgrade is accepted by the public client method.
live = replace_between(
    live,
    '  async requestMediaUpgrade(requestType = "video_upgrade", proposal = {}) {',
    '  async respondMediaUpgrade(mediaRequestId, decision = "accept") {',
    D('''
      async requestMediaUpgrade(requestType = "video_upgrade", proposal = {}) {
        if (this.status !== CALL_STATUS.ACTIVE || !this.callAttemptId) return
        if (requestType !== "video_upgrade") throw new Error("Unsupported media upgrade")
        this.pendingVideoConsentFresh = true

        return new Promise((resolve, reject) => {
          if (!this.channel) return reject(new Error("Channel unavailable"))
          this.channel.push("call:media_request", {
            call_attempt_id: this.callAttemptId,
            request_type: "video_upgrade",
            proposal
          })
            .receive("ok", resolve)
            .receive("error", reject)
        })
      }
    '''),
    "defer screen share client surface"
)
"""
text = text[:screen_plan_start] + screen_plan + text[screen_plan_end:]

# The admitted-call source change is a one-token semantic replacement inside a known private function.
admitted_plan_start = text.index('server = replace_once(\n    server,\n    D(\'\'\'\n      defp admitted_call')
admitted_plan_end = text.index('\n# Replace the entire request media handler', admitted_plan_start)
admitted_plan = r'''admitted_call_old = '      call_pid(pid, message)'
if server.count(admitted_call_old) != 1:
    raise RuntimeError(f"admitted_call endpoint wrapper: expected one call_pid match, found {server.count(admitted_call_old)}")
server = server.replace(admitted_call_old, '      call_pid(pid, wrap_media_endpoint_action(message))', 1)

'''
text = text[:admitted_plan_start] + admitted_plan + text[admitted_plan_end:]

# Defer the long legacy Screen Share handler replacement; the final hardening pass below
# rejects unsupported requests at the public ConversationServer boundary instead.
request_plan_start = text.index('# Replace the entire request media handler so unknown/screen-share requests are rejected.')
request_plan_end = text.index('server_path.write_text(server)', request_plan_start)
text = text[:request_plan_start] + '# Screen Share server request rejection is applied in the final hardening pass.\n' + text[request_plan_end:]

# C11 transformations replace whole functions; use formatter-independent function-name boundaries.
text = text.replace("    '  def admit_and_reserve(state, conversation_id, call_attempt_id, now \\\\ nil) do',", "    '  def admit_and_reserve(',", 1)
text = text.replace("    '  def admit_extension(state, call_attempt_id, now \\\\ nil) do',", "    '  def admit_extension(',", 1)
text = text.replace("    '  def authorize_credentials(provider, _conversation_id, _participant_id, call_attempt_id, ttl) do',", "    '  def authorize_credentials(',", 1)

# Fix the durable endpoint-test insertion so it preserves the module's final newline/end boundary.
text = text.replace(
    '    authority = authority[:pos] + addition + authority[pos:]',
    '    authority = authority[:pos] + "\\n\\n" + addition + authority[pos:]',
    1,
)

# Final hardening is still temporary execution machinery; it materializes direct canonical
# source and durable regressions, then all of this machinery is deleted before closure.
final_marker = 'print("TEAM6_DIRECT_REMEDIATION_APPLIED")'
final_hardening = r'''
# ---------------------------------------------------------------------------
# Final Team 6 provider-independent hardening.
# ---------------------------------------------------------------------------

# T6-005: Screen Share is OUT OF V1. Remove the active UI action and client handler.
app_path = Path("priv/static/assets/app.js")
app = app_path.read_text()
screen_handler = D(r'''
  $("#btn-call-screen-share")?.addEventListener("click", async () => {
    await app.liveCall?.requestMediaUpgrade("screen_share")
  })
''')
app = replace_once(app, screen_handler, "", "remove Screen Share app handler")
app_path.write_text(app)

index_path = Path("priv/static/index.html")
index = index_path.read_text()
index = replace_once(
    index,
    '<button id="btn-call-screen-share" type="button">Share Screen</button>',
    '',
    "remove Screen Share V1 control",
)
index_path.write_text(index)

# Reject unsupported media upgrades before they enter ConversationServer state.
server_path = Path("lib/strangertalks_new/conversation_lifecycle/conversation_server.ex")
server = server_path.read_text()
server = replace_between(
    server,
    '  def request_call_media(',
    '  def respond_call_media(',
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

# Runtime TURN credentials are a production-only secret contract. Test keeps explicit test-only fixtures.
runtime_path = Path("config/runtime.exs")
runtime = runtime_path.read_text()
turn_start = runtime.find('turn_oracle_urls = System.get_env("TURN_ORACLE_URLS"')
prod_marker = '\n\nif config_env() == :prod do'
if turn_start >= 0:
    turn_end = runtime.find(prod_marker, turn_start)
    if turn_end < 0:
        raise RuntimeError("runtime TURN block end not found")
    block = runtime[turn_start:turn_end].strip("\n")
    if not block.startswith("if config_env() == :prod do"):
        indented = "\n".join(("  " + line) if line else "" for line in block.splitlines())
        runtime = runtime[:turn_start] + "if config_env() == :prod do\n" + indented + "\nend" + runtime[turn_end:]
runtime_path.write_text(runtime)

# Strengthen durable Screen Share product-truth proof.
privacy_path = Path("test/js/team6_media_privacy_test.mjs")
privacy = privacy_path.read_text()
if "active-call V1 UI has no Screen Share action" not in privacy:
    privacy += D(r'''

      test("active-call V1 UI has no Screen Share action", () => {
        const html = readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
        assert.doesNotMatch(html, /btn-call-screen-share|Share Screen/i)
      })
    ''') + "\n"
privacy_path.write_text(privacy)

# Strengthen server truth: even the authoritative endpoint cannot request deferred Screen Share.
authority_path = Path("test/strangertalks_new/team6_media_authority_test.exs")
authority = authority_path.read_text()
if "authoritative endpoint cannot request deferred screen share" not in authority:
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
        raise RuntimeError("authority test module end not found during Screen Share hardening")
    authority = authority[:pos] + "\n\n" + addition + authority[pos:]
authority_path.write_text(authority)

# Provider contract must fail closed for malformed configuration and never enter browser source.
turn_test_path = Path("test/strangertalks_new/team6_turn_provider_test.exs")
turn_test = turn_test_path.read_text()
if "malformed provider configuration fails closed" not in turn_test:
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
    pos = turn_test.rfind("\nend")
    if pos < 0:
        raise RuntimeError("TURN provider test module end not found")
    turn_test = turn_test[:pos] + "\n\n" + addition + turn_test[pos:]
turn_test_path.write_text(turn_test)
'''
if final_hardening not in text:
    text = text.replace(final_marker, final_hardening + "\n\n" + final_marker, 1)

path.write_text(text)
print("TEAM6_REMEDIATION_HARNESS_PREPARED")
