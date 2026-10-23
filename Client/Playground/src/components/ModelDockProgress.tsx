import { useEffect, useState } from 'react'
import { useStore } from '../store'

export default function ModelDockProgress({ taskId, roundId }: { taskId?: string; roundId?: string }) {
  const task = useStore((state) => state.tasks.find((item) => item.status === 'running' && item.apiProfileId === 'modeldock-local-image' && (taskId ? item.id === taskId : item.agentRoundId === roundId)))
  const [progress, setProgress] = useState({ percent: 0, label: '等待图片任务' })
  useEffect(() => {
    if (!task) return
    let closed = false
    const controller = new AbortController()
    const poll = async () => {
      try {
        const response = await fetch('/modeldock/progress?job_id=' + encodeURIComponent(task.id), { cache: 'no-store', signal: controller.signal })
        if (!response.ok) return
        const value = await response.json()
        if (closed || value.job_id !== task.id) return
        const labels: Record<string, string> = { loading: '加载模型', encoding: '理解提示词', encoding_image: '读取原图', denoising: '生成图片', decoding: '解码图片', complete: '生成完成', failed: '生成失败', cancelled: '已取消' }
        const steps = Number(value.total)
        const completed = Number(value.completed)
        const percent = value.stage === 'complete' ? 100 : value.stage === 'decoding' ? 95 : value.stage === 'denoising' && steps > 0 && Number.isFinite(completed) ? Math.min(94, Math.max(5, Math.round(5 + completed / steps * 89))) : 0
        setProgress({ percent, label: labels[value.stage] ?? '准备图片任务' })
      } catch (error) {
        if (!controller.signal.aborted) console.warn('读取本地图片进度失败', error)
      }
    }
    setProgress({ percent: 0, label: '等待图片任务' })
    void poll()
    const timer = window.setInterval(() => void poll(), 800)
    return () => { closed = true; controller.abort(); window.clearInterval(timer) }
  }, [task?.id])
  if (!task) return <span>正在理解请求…</span>
  return <span className="inline-flex min-w-40 flex-col gap-2 text-xs" role="progressbar" aria-label={progress.label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={progress.percent}>
    <span className="flex justify-between gap-3"><span>{progress.label}</span><span className="tabular-nums">{progress.percent}%</span></span>
    <span className="h-1.5 overflow-hidden rounded-full bg-blue-100 dark:bg-blue-950"><span className="block h-full bg-blue-500 transition-[width]" style={{ width: progress.percent + '%' }} /></span>
  </span>
}
