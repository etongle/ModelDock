import { useEffect, useRef, useState } from 'react'
import { MODELDOCK_IMAGE_PRESETS, modelDockSizeError } from '../lib/modelDockImage'
import { usePreventBackgroundScroll } from '../hooks/usePreventBackgroundScroll'

export default function ModelDockSizePicker({ currentSize, onSelect, onClose }: {
  currentSize: string
  onSelect: (size: string) => void
  onClose: () => void
}) {
  usePreventBackgroundScroll(true)
  const [size, setSize] = useState(currentSize || 'auto')
  const [width, setWidth] = useState(currentSize.split('x')[0] === 'auto' ? '1024' : currentSize.split('x')[0])
  const [height, setHeight] = useState(currentSize.split('x')[1] || '1024')
  const closeRef = useRef<HTMLButtonElement>(null)
  const error = modelDockSizeError(size)
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    closeRef.current?.focus()
    return () => previous?.focus()
  }, [])
  const chip = (active: boolean) => `rounded-xl border px-3 py-2 text-left text-sm transition ${active
    ? 'border-blue-400 bg-blue-50 text-blue-600 dark:border-blue-500/50 dark:bg-blue-500/10 dark:text-blue-300'
    : 'border-transparent bg-black/[0.04] text-gray-600 hover:bg-black/[0.07] dark:bg-white/[0.06] dark:text-gray-300 dark:hover:bg-white/[0.1]'}`
  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-black/30 p-4 backdrop-blur-sm" onClick={(event) => { if (event.target === event.currentTarget) onClose() }} onKeyDown={(event) => {
      if (event.key === 'Escape') onClose()
      if (event.key === 'Tab') {
        const controls = Array.from(event.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled), input'))
        const first = controls[0]
        const last = controls[controls.length - 1]
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
        if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
      }
    }}>
      <section role="dialog" aria-modal="true" aria-labelledby="modeldock-size-title" className="relative max-h-[90dvh] w-full max-w-lg overflow-y-auto rounded-3xl border border-white/50 bg-white/95 p-5 shadow-2xl dark:border-white/[0.08] dark:bg-gray-900/95">
        <div className="mb-4 flex items-start justify-between gap-4">
          <div><h3 id="modeldock-size-title" className="font-semibold text-gray-800 dark:text-gray-100">本地图像尺寸</h3><p className="mt-1 text-xs text-gray-500">Qwen Turbo · 标准 8 步 · PNG 无损输出</p></div>
          <button ref={closeRef} onClick={onClose} aria-label="关闭" className="rounded-lg p-2 text-gray-500 hover:bg-gray-100 dark:hover:bg-white/10">✕</button>
        </div>
        <button onClick={() => setSize('auto')} className={`${chip(size === 'auto')} mb-3 w-full`}><strong className="block">自动 / 保持原图尺寸</strong><span className="text-xs">新建默认 1024×1024；编辑沿用参考图尺寸</span></button>
        <div className="grid grid-cols-2 gap-2">{MODELDOCK_IMAGE_PRESETS.map((preset) => <button key={preset.size} onClick={() => { setSize(preset.size); const [w, h] = preset.size.split('x'); setWidth(w); setHeight(h) }} className={chip(size === preset.size)}><span className="block">{preset.label}</span><span className="text-xs opacity-70">{preset.size.replace('x', ' × ')}</span></button>)}</div>
        <fieldset className="mt-4"><legend className="mb-2 text-sm text-gray-700 dark:text-gray-300">自定义尺寸</legend><div className="flex items-center gap-2"><label className="flex-1 text-xs text-gray-500">宽度<input type="number" min="256" max="2048" step="32" value={width} onChange={(event) => { setWidth(event.target.value); setSize(`${event.target.value}x${height}`) }} className="mt-1 w-full rounded-lg border border-gray-200 bg-transparent px-3 py-2 text-sm dark:border-white/10" /></label><span className="mt-4 text-gray-400">×</span><label className="flex-1 text-xs text-gray-500">高度<input type="number" min="256" max="2048" step="32" value={height} onChange={(event) => { setHeight(event.target.value); setSize(`${width}x${event.target.value}`) }} className="mt-1 w-full rounded-lg border border-gray-200 bg-transparent px-3 py-2 text-sm dark:border-white/10" /></label></div></fieldset>
        <p className="mt-3 text-xs text-gray-500">每边 256–2048 像素，32 的倍数。大图更耗时、占用更多内存。尺寸增加像素，不保证修复模糊；局部修改请使用遮罩保留其他区域。</p>
        {error && <p role="alert" className="mt-2 text-xs text-red-600">{error}</p>}
        <div className="mt-5 flex items-center justify-between gap-3"><span className="text-sm text-gray-500">{size === 'auto' ? '保持原图 / 自动' : size.replace('x', ' × ')}</span><button disabled={!!error} onClick={() => { onSelect(size); onClose() }} className="rounded-xl bg-blue-500 px-5 py-2 text-sm font-medium text-white hover:bg-blue-600 disabled:opacity-40">应用尺寸</button></div>
      </section>
    </div>
  )
}
