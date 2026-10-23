import { importCustomProviderSettingsFromJson } from './apiProfiles'

export async function loadModelDockConfig() {
  const response = await fetch('/modeldock/config.json', { cache: 'no-store' })
  if (!response.ok) throw new Error('无法读取当前 ModelDock 方案配置')
  return importCustomProviderSettingsFromJson(await response.text(), [], { deploymentConfig: true })
}
