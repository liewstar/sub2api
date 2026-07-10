export interface UsageMetricsRow {
  input_tokens?: number | null
  output_tokens?: number | null
  cache_creation_tokens?: number | null
  cache_read_tokens?: number | null
  duration_ms?: number | null
}

const finiteNonNegative = (value: number | null | undefined): number => {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return 0
  return value
}

export function getUsageCacheUtilization(row: UsageMetricsRow | null | undefined): number | null {
  if (!row) return null
  const inputTokens = finiteNonNegative(row.input_tokens)
  const cacheReadTokens = finiteNonNegative(row.cache_read_tokens)
  const cacheCreationTokens = finiteNonNegative(row.cache_creation_tokens)
  const promptTokens = inputTokens + cacheReadTokens + cacheCreationTokens
  if (promptTokens <= 0) return null
  return (cacheReadTokens / promptTokens) * 100
}

export function getUsageOutputTPS(row: UsageMetricsRow | null | undefined): number | null {
  if (!row) return null
  const durationMs = finiteNonNegative(row.duration_ms)
  if (durationMs <= 0) return null
  return finiteNonNegative(row.output_tokens) / (durationMs / 1000)
}

export function formatUsageCacheUtilization(row: UsageMetricsRow | null | undefined): string {
  const value = getUsageCacheUtilization(row)
  if (value == null) return '-'
  return `${value.toFixed(1)}%`
}

export function formatUsageOutputTPS(row: UsageMetricsRow | null | undefined): string {
  const value = getUsageOutputTPS(row)
  if (value == null) return '-'
  if (value >= 100) return value.toFixed(0)
  if (value >= 10) return value.toFixed(1)
  return value.toFixed(2)
}
