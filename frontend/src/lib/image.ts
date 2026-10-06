/** Reads an image file and returns a JPEG/PNG data URL scaled to at most `maxSize` px (keeps Firestore docs small). */
export function fileToResizedDataUrl(file: File, maxSize = 512, quality = 0.85): Promise<string | null> {
  return new Promise((resolve) => {
    const reader = new FileReader()
    reader.onerror = () => resolve(null)
    reader.onload = () => {
      const src = typeof reader.result === 'string' ? reader.result : null
      if (!src) return resolve(null)
      const img = new Image()
      img.onerror = () => resolve(src)
      img.onload = () => {
        const scale = Math.min(1, maxSize / Math.max(img.width, img.height))
        if (scale >= 1 && file.size < 200_000) return resolve(src)
        const canvas = document.createElement('canvas')
        canvas.width = Math.round(img.width * scale)
        canvas.height = Math.round(img.height * scale)
        const ctx = canvas.getContext('2d')
        if (!ctx) return resolve(src)
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
        resolve(canvas.toDataURL('image/jpeg', quality))
      }
      img.src = src
    }
    reader.readAsDataURL(file)
  })
}

export function pickImageDataUrl(maxSize = 512): Promise<string | null> {
  return new Promise((resolve) => {
    const input = document.createElement('input')
    input.type = 'file'
    input.accept = 'image/*'
    input.onchange = async () => {
      const f = input.files?.[0]
      resolve(f ? await fileToResizedDataUrl(f, maxSize) : null)
    }
    input.oncancel = () => resolve(null)
    input.click()
  })
}
