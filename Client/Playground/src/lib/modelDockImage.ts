import type { ApiProfile } from '../types'

export function isModelDockImageProfile(profile: ApiProfile) {
  return profile.id === 'modeldock-local-image' && profile.model.endsWith('/Qwen-Image-2.1-Turbo')
}

export const MODELDOCK_IMAGE_PRESETS = [
  { label: '预览 · 方形', size: '512x512' },
  { label: '标准 · 方形', size: '1024x1024' },
  { label: '精细 · 方形', size: '1536x1536' },
  { label: '大图 · 方形', size: '2048x2048' },
  { label: '横版 · 16:9', size: '1536x864' },
  { label: '竖版 · 9:16', size: '864x1536' },
  { label: '横版 · 4:3', size: '1024x768' },
  { label: '竖版 · 3:4', size: '768x1024' },
  { label: '横版 · 3:2', size: '1536x1024' },
  { label: '竖版 · 2:3', size: '1024x1536' },
]

export function modelDockSizeError(size: string) {
  if (size === 'auto') return ''
  if (!/^\d{3,4}x\d{3,4}$/.test(size)) return '请输入整数宽度和高度。'
  const [width, height] = size.split('x').map(Number)
  if (![width, height].every((side) => side >= 256 && side <= 2048 && side % 32 === 0)) {
    return '宽高须为 32 的倍数，每边 256–2048 像素。'
  }
  return Math.max(width, height) > Math.min(width, height) * 4 ? '长宽比不能超过 4:1。' : ''
}
