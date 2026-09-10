import assert from "node:assert/strict"
import fs from "node:fs"

const doorMapping = fs.readFileSync(new URL("../../priv/static/assets/door_mapping.mjs", import.meta.url), "utf8")
const placement = fs.readFileSync(new URL("../../priv/static/assets/interface_language_placement.mjs", import.meta.url), "utf8")

assert.match(
  doorMapping,
  /import "\.\/interface_language_placement\.mjs"/,
  "Door runtime must install the interface-language placement layer"
)

assert.match(placement, /getElementById\("conversation-language"\)/)
assert.match(placement, /label\[for=\\?"conversation-language\\?"\]/)
assert.match(placement, /header\.append\(control\)/)
assert.match(placement, /data-interface-language-placement", "global-secondary"/)
assert.match(placement, /conversation-language-help/)
assert.match(placement, /arrival-feedback/)

assert.doesNotMatch(
  placement,
  /queue:join|conversation_language|CONVERSATION_LANGUAGES|backendDoorFor/,
  "Placement layer must not redefine matching or language-contract semantics"
)

console.log("interface language placement contract passed")
