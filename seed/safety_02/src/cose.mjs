import {decode, encode, rfc8949EncodeOptions} from "cborg"

const EMPTY = new Uint8Array()
const EDDSA = -8
const encoder = new TextEncoder()
const decoder = new TextDecoder("utf-8", {fatal: true})

export function protocolError(code, cause = undefined) {
  const error = new Error(code, cause ? {cause} : undefined)
  error.code = code
  return error
}

export function equalBytes(a, b) {
  if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array) || a.byteLength !== b.byteLength) return false
  let diff = 0
  for (let i = 0; i < a.byteLength; i += 1) diff |= a[i] ^ b[i]
  return diff === 0
}

export function bytesToHex(bytes) {
  return [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("")
}

export function canonicalEncode(value) {
  return encode(value, rfc8949EncodeOptions)
}

export function canonicalDecode(bytes, {useMaps = false, errorCode = "malformed_cbor"} = {}) {
  if (!(bytes instanceof Uint8Array)) throw protocolError(errorCode)
  try {
    const value = decode(bytes, {strict: true, allowIndefinite: false, allowNaN: false, allowInfinity: false, useMaps})
    if (!equalBytes(bytes, canonicalEncode(value))) throw protocolError(errorCode)
    return value
  } catch (error) {
    if (error?.code === errorCode) throw error
    throw protocolError(errorCode, error)
  }
}

export async function digestBytes(bytes) {
  if (!(bytes instanceof Uint8Array)) throw protocolError("invalid_digest_input")
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
}

function cryptoKeyLike(value, usage, type) {
  return Boolean(value && typeof value === "object" && value.type === type && value.algorithm?.name === "Ed25519" &&
    Array.isArray(value.usages) && value.usages.includes(usage))
}

async function importPublic(raw) {
  if (!(raw instanceof Uint8Array) || raw.byteLength !== 32) throw protocolError("invalid_public_key")
  return crypto.subtle.importKey("raw", raw, "Ed25519", true, ["verify"])
}

export async function generateEd25519Pair() {
  const pair = await crypto.subtle.generateKey("Ed25519", false, ["sign", "verify"])
  const publicKeyBytes = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))
  return {privateKey: pair.privateKey, publicKey: pair.publicKey, publicKeyBytes}
}

function parseCose(bytes) {
  const cose = canonicalDecode(bytes, {useMaps: true, errorCode: "malformed_cose"})
  if (!Array.isArray(cose) || cose.length !== 4) throw protocolError("malformed_cose")
  const [protectedBytes, unprotected, payloadBytes, signature] = cose
  if (!(protectedBytes instanceof Uint8Array) || !(unprotected instanceof Map) || unprotected.size !== 0 ||
      !(payloadBytes instanceof Uint8Array) || !(signature instanceof Uint8Array) || signature.byteLength !== 64) throw protocolError("malformed_cose")
  const headers = canonicalDecode(protectedBytes, {useMaps: true, errorCode: "malformed_cose"})
  if (!(headers instanceof Map) || headers.get(1) !== EDDSA || !(headers.get(4) instanceof Uint8Array)) throw protocolError("malformed_cose")
  let kid
  try { kid = decoder.decode(headers.get(4)) } catch (error) { throw protocolError("malformed_cose", error) }
  if (!kid) throw protocolError("malformed_cose")
  return {protectedBytes, payloadBytes, signature, kid}
}

export function decodeCosePayload(bytes) {
  return canonicalDecode(parseCose(bytes).payloadBytes, {errorCode: "malformed_cose_payload"})
}

export async function createCoseSign1({payload, privateKey, kid}) {
  if (!cryptoKeyLike(privateKey, "sign", "private") || typeof kid !== "string" || !kid) throw protocolError("invalid_signer")
  const payloadBytes = canonicalEncode(payload)
  const protectedBytes = canonicalEncode(new Map([[1, EDDSA], [4, encoder.encode(kid)]]))
  const toSign = canonicalEncode(["Signature1", protectedBytes, EMPTY, payloadBytes])
  const signature = new Uint8Array(await crypto.subtle.sign("Ed25519", privateKey, toSign))
  return canonicalEncode([protectedBytes, new Map(), payloadBytes, signature])
}

export async function verifyCoseSign1({coseBytes, resolvePublicKey, missingKeyCode = "unknown_signing_key", invalidSignatureCode = "invalid_signature"}) {
  const envelope = parseCose(coseBytes)
  let key = await resolvePublicKey(envelope.kid)
  if (!key) throw protocolError(missingKeyCode)
  if (!cryptoKeyLike(key, "verify", "public")) key = await importPublic(key)
  const toVerify = canonicalEncode(["Signature1", envelope.protectedBytes, EMPTY, envelope.payloadBytes])
  if (!await crypto.subtle.verify("Ed25519", key, envelope.signature, toVerify)) throw protocolError(invalidSignatureCode)
  return {
    kid: envelope.kid,
    payload: canonicalDecode(envelope.payloadBytes, {errorCode: "malformed_cose_payload"}),
    digest: await digestBytes(coseBytes)
  }
}
