// @vitest-environment jsdom
import { act } from 'react'
import { createRoot } from 'react-dom/client'
import { afterEach, expect, it, vi } from 'vitest'
import ModelDockProgress from './ModelDockProgress'

vi.mock('../store', () => ({ useStore: (select: (state: unknown) => unknown) => select({ tasks: [{ id: 'live-image', status: 'running', apiProfileId: 'modeldock-local-image', agentRoundId: 'round-1' }] }) }))
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals() })

it('advances from actual matching model steps and ignores another job', async () => {
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true)
  vi.useFakeTimers()
  const fetcher = vi.fn()
    .mockResolvedValueOnce(new Response(JSON.stringify({ job_id: 'another-job', stage: 'complete', completed: 8, total: 8 })))
    .mockResolvedValueOnce(new Response(JSON.stringify({ job_id: 'live-image', stage: 'denoising', completed: 4, total: 8 })))
    .mockResolvedValueOnce(new Response(JSON.stringify({ job_id: 'live-image', stage: 'decoding', completed: 8, total: 8 })))
  vi.stubGlobal('fetch', fetcher)
  const host = document.createElement('div')
  const root = createRoot(host)
  await act(async () => { root.render(<ModelDockProgress roundId="round-1" />) })
  expect(host.querySelector('[role="progressbar"]')?.getAttribute('aria-valuenow')).toBe('0')
  await act(async () => { await vi.advanceTimersByTimeAsync(800) })
  expect(host.textContent).toContain('生成图片50%')
  expect(host.querySelector('[role="progressbar"]')?.getAttribute('aria-valuenow')).toBe('50')
  await act(async () => { await vi.advanceTimersByTimeAsync(800) })
  expect(host.textContent).toContain('解码图片95%')
  expect(fetcher).toHaveBeenCalledWith('/modeldock/progress?job_id=live-image', expect.objectContaining({ cache: 'no-store' }))
  await act(async () => { root.unmount() })
  expect(vi.getTimerCount()).toBe(0)
})
