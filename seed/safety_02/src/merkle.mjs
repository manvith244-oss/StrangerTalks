import {encode, rfc8949EncodeOptions} from "cborg"

function protocolError(code) {
  const error = new Error(code)
  error.code = code
  return error
}

function equalBytes(a, b) {
  if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array) || a.byteLength !== b.byteLength) return false
  let diff = 0
  for (let i = 0; i < a.byteLength; i += 1) diff |= a[i] ^ b[i]
  return diff === 0
}

function concatBytes(...parts) {
  const total = parts.reduce((sum, part) => sum + part.byteLength, 0)
  const out = new Uint8Array(total)
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.byteLength
  }
  return out
}

async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
}

function largestPowerOfTwoLessThan(n) {
  let k = 1
  while ((k << 1) < n) k <<= 1
  return k
}

async function leafHash(leaf) {
  return sha256(concatBytes(new Uint8Array([0]), leaf))
}

async function nodeHash(left, right) {
  return sha256(concatBytes(new Uint8Array([1]), left, right))
}

export function acceptanceLeafBytes(globalSequence, messageDigest) {
  if (!Number.isInteger(globalSequence) || globalSequence < 1 || !(messageDigest instanceof Uint8Array)) {
    throw protocolError("invalid_acceptance_leaf")
  }
  return encode([globalSequence, messageDigest], rfc8949EncodeOptions)
}

export async function merkleRoot(leaves) {
  if (!Array.isArray(leaves)) throw protocolError("invalid_merkle_input")
  if (leaves.length === 0) return sha256(new Uint8Array())
  if (leaves.length === 1) return leafHash(leaves[0])
  const k = largestPowerOfTwoLessThan(leaves.length)
  return nodeHash(await merkleRoot(leaves.slice(0, k)), await merkleRoot(leaves.slice(k)))
}

export async function inclusionProof(leaves, index) {
  if (!Array.isArray(leaves) || !Number.isInteger(index) || index < 0 || index >= leaves.length) {
    throw protocolError("invalid_inclusion_request")
  }
  async function path(segment, localIndex) {
    if (segment.length === 1) return []
    const k = largestPowerOfTwoLessThan(segment.length)
    if (localIndex < k) {
      return [...await path(segment.slice(0, k), localIndex), await merkleRoot(segment.slice(k))]
    }
    return [...await path(segment.slice(k), localIndex - k), await merkleRoot(segment.slice(0, k))]
  }
  return path(leaves, index)
}

export async function verifyInclusionProof({leaf, index, treeSize, proof, root}) {
  if (!(leaf instanceof Uint8Array) || !(root instanceof Uint8Array) || !Array.isArray(proof) ||
      !Number.isInteger(index) || !Number.isInteger(treeSize) || treeSize < 1 || index < 0 || index >= treeSize ||
      !proof.every(node => node instanceof Uint8Array)) return false

  const cursor = {value: 0}
  async function reconstruct(localIndex, size, currentLeafHash) {
    if (size === 1) return currentLeafHash
    const k = largestPowerOfTwoLessThan(size)
    if (localIndex < k) {
      const left = await reconstruct(localIndex, k, currentLeafHash)
      const sibling = proof[cursor.value++]
      if (!(sibling instanceof Uint8Array)) throw protocolError("invalid_inclusion_proof")
      return nodeHash(left, sibling)
    }
    const right = await reconstruct(localIndex - k, size - k, currentLeafHash)
    const sibling = proof[cursor.value++]
    if (!(sibling instanceof Uint8Array)) throw protocolError("invalid_inclusion_proof")
    return nodeHash(sibling, right)
  }

  try {
    const reconstructed = await reconstruct(index, treeSize, await leafHash(leaf))
    return cursor.value === proof.length && equalBytes(reconstructed, root)
  } catch (_error) {
    return false
  }
}

export async function buildFinalCommitment({serverAuthority, sessionId, acceptedRecords, finalizedAt}) {
  if (!serverAuthority?.sign || typeof sessionId !== "string" || !Array.isArray(acceptedRecords) || !Number.isInteger(finalizedAt)) {
    throw protocolError("invalid_final_commitment_input")
  }
  const ordered = [...acceptedRecords].sort((a, b) => a.global_sequence - b.global_sequence)
  ordered.forEach((record, index) => {
    if (record.global_sequence !== index + 1 || !(record.message_digest instanceof Uint8Array)) {
      throw protocolError("non_contiguous_acceptance_log")
    }
  })
  const leaves = ordered.map(record => acceptanceLeafBytes(record.global_sequence, record.message_digest))
  const root = await merkleRoot(leaves)
  const payload = {
    kind: "final_session_commitment",
    version: 1,
    session_id: sessionId,
    final_accepted_sequence: ordered.length,
    accepted_count: ordered.length,
    merkle_root: root,
    merkle_algorithm: "RFC6962_SHA256_ORDERED_V1",
    finalized_at: finalizedAt
  }
  const cose = await serverAuthority.sign(payload)
  const proofs = new Map()
  for (let i = 0; i < leaves.length; i += 1) proofs.set(i + 1, await inclusionProof(leaves, i))
  return {
    cose,
    root,
    treeSize: leaves.length,
    proofFor(globalSequence) {
      const proof = proofs.get(globalSequence)
      if (!proof) throw protocolError("unknown_acceptance_sequence")
      return proof.map(node => new Uint8Array(node))
    }
  }
}
