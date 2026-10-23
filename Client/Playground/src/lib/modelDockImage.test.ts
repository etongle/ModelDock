import { describe, expect, it } from 'vitest'
import { DEFAULT_PARAMS } from '../types'
import { createDefaultOpenAIProfile, DEFAULT_SETTINGS, normalizeSettings } from './apiProfiles'
import { normalizeParamsForSettings } from './paramCompatibility'
import { MODELDOCK_IMAGE_PRESETS, modelDockSizeError } from './modelDockImage'
import { agentMaskForReferences } from './agentMask'

describe('ModelDock local image compatibility', () => {
  it('keeps small and custom sizes without applying OpenAI pixel limits', () => {
    const profile = createDefaultOpenAIProfile({ id: 'modeldock-local-image', model: 'local/Qwen/Qwen-Image-2.1-Turbo' })
    const settings = normalizeSettings({ ...DEFAULT_SETTINGS, profiles: [profile], activeProfileId: profile.id })
    for (const size of ['512x512', '1536x864', '2048x2048', 'auto']) {
      expect(normalizeParamsForSettings({ ...DEFAULT_PARAMS, size }, settings).size).toBe(size)
    }
    expect(MODELDOCK_IMAGE_PRESETS.every((preset) => !modelDockSizeError(preset.size))).toBe(true)
    for (const size of ['1280x720', '256x2048', '4096x4096', 'x', '256.5x512']) {
      expect(modelDockSizeError(size)).not.toBe('')
    }
  })

  it('binds a mask only to its exact reference, preventing silent global redraws', () => {
    const round = { maskTargetImageId: 'original', maskImageId: 'mask' }
    expect(agentMaskForReferences(round, 'data:mask', ['original'])).toEqual({
      maskDataUrl: 'data:mask', maskTargetImageId: 'original', maskImageId: 'mask',
    })
    for (const ids of [[], ['other'], ['original', 'other']]) {
      expect(() => agentMaskForReferences(round, 'data:mask', ids)).toThrow('遮罩对应')
    }
    expect(agentMaskForReferences({}, undefined, ['other']).maskImageId).toBeNull()
  })
})
