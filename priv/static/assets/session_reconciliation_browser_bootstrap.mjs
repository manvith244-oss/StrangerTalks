import {Socket} from "/vendor/phoenix.mjs"
import {installCanonicalIndexedDB} from "./f11_local_store.mjs"
import {installF11Runtime} from "./f11_persistence_runtime.mjs"

// Browser-only F-11 bootstrap. session_reconciliation_guard.mjs stays
// importable in plain Node so race/reconciliation contracts exercise the
// same guard logic without resolving endpoint-served browser dependencies.
installCanonicalIndexedDB(globalThis)
installF11Runtime({SocketClass: Socket})
