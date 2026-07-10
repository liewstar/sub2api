import { describe, expect, it } from 'vitest'

import {
  formatUsageCacheUtilization,
  formatUsageOutputTPS,
  getUsageCacheUtilization,
  getUsageOutputTPS,
} from '../usageMetrics'

describe('usageMetrics', () => {
  it('calculates cache utilization against all prompt-side tokens', () => {
    const row = {
      input_tokens: 200,
      cache_read_tokens: 500,
      cache_creation_tokens: 300,
    }

    expect(getUsageCacheUtilization(row)).toBe(50)
    expect(formatUsageCacheUtilization(row)).toBe('50.0%')
  })

  it('returns null cache utilization when no prompt-side tokens exist', () => {
    expect(getUsageCacheUtilization({
      input_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0,
    })).toBeNull()
    expect(formatUsageCacheUtilization(null)).toBe('-')
  })

  it('calculates output TPS from output tokens and duration', () => {
    const row = {
      output_tokens: 120,
      duration_ms: 3000,
    }

    expect(getUsageOutputTPS(row)).toBe(40)
    expect(formatUsageOutputTPS(row)).toBe('40.0')
  })

  it('returns null TPS when duration is missing or zero', () => {
    expect(getUsageOutputTPS({ output_tokens: 120, duration_ms: 0 })).toBeNull()
    expect(formatUsageOutputTPS({ output_tokens: 120, duration_ms: null })).toBe('-')
  })
})
