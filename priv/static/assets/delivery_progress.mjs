export function createDeliveryProgress(epochId, baselineSequence, storedSequence = 0) {
  const baseline = Number.isInteger(baselineSequence) && baselineSequence > 0 ? baselineSequence : 1
  const floor = baseline - 1
  const contiguous = Math.max(floor, Number.isInteger(storedSequence) ? storedSequence : floor)

  return {epochId, baseline, contiguous, applied: new Set()}
}

export function applyCanonicalSequence(progress, sequence) {
  if (!Number.isInteger(sequence) || sequence <= 0 || sequence <= progress.contiguous) return progress

  const applied = new Set(progress.applied)
  applied.add(sequence)
  let contiguous = progress.contiguous

  while (applied.has(contiguous + 1)) {
    applied.delete(contiguous + 1)
    contiguous += 1
  }

  return {...progress, contiguous, applied}
}
