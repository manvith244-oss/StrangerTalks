import assert from "node:assert/strict"
import fs from "node:fs"

const doorMapping = fs.readFileSync(new URL("../../priv/static/assets/door_mapping.mjs", import.meta.url), "utf8")
const index = fs.readFileSync(new URL("../../priv/static/index.html", import.meta.url), "utf8")
const catalog = fs.readFileSync(new URL("../../priv/static/assets/conversation_catalog.mjs", import.meta.url), "utf8")

assert.doesNotMatch(doorMapping, /interface_language_placement/)
assert.doesNotMatch(index, /id="conversation-language"/)
assert.match(index, /id="hangout-language"/)
assert.match(catalog, /English/)
assert.match(catalog, /Telugu/)
assert.match(catalog, /Hindi/)
assert.match(doorMapping, /return door_type \? \{door_type\} : null/)
assert.doesNotMatch(doorMapping, /conversation_language|futureConversationLanguageForQueue/)

console.log("Four Doors language-independent queue contract passed")
