export function dataUrlToBlob(dataUrl: string): { blob: Blob; contentType: string } | null {
  const raw = dataUrl.trim()
  if (!raw.startsWith('data:')) return null
  const comma = raw.indexOf(',')
  if (comma <= 0) return null
  const meta = raw.slice(5, comma).split(';')
  const contentType = meta[0]?.trim() || 'application/octet-stream'
  try {
    const bin = atob(raw.slice(comma + 1))
    const bytes = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
    return { blob: new Blob([bytes], { type: contentType }), contentType }
  } catch {
    return null
  }
}

export const sanitizeUploadName = (raw: string, fallback = 'file.bin') => {
  const t = raw.trim()
  return t ? t.replace(/[^A-Za-z0-9._-]/g, '_') : fallback
}

export function pickFile(accept: string): Promise<File | null> {
  return new Promise((resolve) => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = accept
    input.onchange = () => resolve(input.files?.[0] ?? null)
    input.oncancel = () => resolve(null)
    input.click()
  })
}
