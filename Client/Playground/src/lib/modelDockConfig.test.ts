import { afterEach, describe, expect, it, vi } from 'vitest'
import { loadModelDockConfig } from './modelDockConfig'

afterEach(() => vi.unstubAllGlobals())

describe('current ModelDock solution', () => {
  it('fetches the same-origin configuration and imports the paired Agent services', async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response(JSON.stringify({ profiles: [
      { id: 'modeldock-local-image', name: '本地生图 · 实例 ABC123', provider: 'openai', isDefault: true, apiMode: 'images', model: 'local-image', apiKey: 'modeldock-loopback', baseUrl: 'http://127.0.0.1:18791/modeldock/v1/' },
      { id: 'modeldock-local-chat', name: '本地对话', provider: 'openai', apiMode: 'responses', model: 'local-chat', apiKey: 'modeldock-loopback', baseUrl: 'http://127.0.0.1:18791/modeldock/v1/' },
    ], agent: { apiConfigMode: 'hybrid', imageProfileId: 'modeldock-local-image', textProfileId: 'modeldock-local-chat' } })))
    vi.stubGlobal('fetch', fetcher)
    const config = await loadModelDockConfig()
    expect(fetcher).toHaveBeenCalledWith('/modeldock/config.json', { cache: 'no-store' })
    expect(config?.agent?.apiConfigMode).toBe('hybrid')
    expect(config?.profiles[0].name).toContain('ABC123')
  })

  it('reports unavailable solution configuration instead of silently using defaults', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('', { status: 503 })))
    await expect(loadModelDockConfig()).rejects.toThrow('当前 ModelDock 方案配置')
  })
})
