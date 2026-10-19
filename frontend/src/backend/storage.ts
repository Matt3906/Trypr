import { apiFetch, apiUrl } from './api'

export class StorageService { readonly type = 'storage' }
export const getStorage = () => new StorageService()

export class StorageReference {
  constructor(readonly fullPath: string) {}
  get name(): string { return this.fullPath.split('/').pop()! }
}

export const ref = (_s: StorageService, path: string) => new StorageReference(path.replace(/^\/+/, ''))

export async function uploadBytes(
  r: StorageReference,
  data: Blob | Uint8Array | ArrayBuffer,
  metadata?: { contentType?: string; customMetadata?: Record<string, string> },
) {
  const blob = data instanceof Blob ? data : new Blob([data as BlobPart])
  const contentType = metadata?.contentType || blob.type || 'application/octet-stream'
  const form = new FormData()
  form.set('path', r.fullPath)
  form.set('contentType', contentType)
  form.set('customMetadata', JSON.stringify(metadata?.customMetadata ?? {}))
  form.set('file', blob, r.name)
  await apiFetch('/api/files/upload', { form })
  return { ref: r, metadata: { contentType, customMetadata: metadata?.customMetadata ?? {} } }
}

export async function getDownloadURL(r: StorageReference): Promise<string> {
  return apiUrl(`/api/files/${r.fullPath.split('/').map(encodeURIComponent).join('/')}`)
}
