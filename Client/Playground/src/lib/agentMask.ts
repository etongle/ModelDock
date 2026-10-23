export function agentMaskForReferences(
  round: { maskTargetImageId?: string | null; maskImageId?: string | null },
  maskDataUrl: string | undefined,
  imageIds: string[],
) {
  if (maskDataUrl && (imageIds.length !== 1 || imageIds[0] !== round.maskTargetImageId)) {
    throw new Error('局部编辑必须使用遮罩对应的那张原图，请明确选择该参考图后重试。')
  }
  return {
    maskDataUrl,
    maskTargetImageId: maskDataUrl ? round.maskTargetImageId ?? null : null,
    maskImageId: maskDataUrl ? round.maskImageId ?? null : null,
  }
}
