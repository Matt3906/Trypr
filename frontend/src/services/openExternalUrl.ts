export function openExternalUrl(url: string, opts: { sameTab?: boolean } = {}): boolean {
  try {
    if (opts.sameTab) {
      window.location.assign(url)
      return true
    }
    return !!window.open(url, '_blank', 'noopener,noreferrer')
  } catch {
    return false
  }
}
