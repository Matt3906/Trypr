export const PREVIEW_W = 280
export const PREVIEW_MAP_H = 160
export const PREVIEW_INFO_H = 64
export const PREVIEW_TRI_H = 10
export const PREVIEW_H = PREVIEW_MAP_H + PREVIEW_INFO_H

/** Small speech-bubble preview card with an OpenStreetMap embed (positioned by the parent). */
export default function MapPreview3D({ lat, lon, title, region }: { lat: number; lon: number; title?: string; region?: string }) {
  const span = 0.01
  const url = `https://www.openstreetmap.org/export/embed.html?bbox=${[lon - span, lat - span, lon + span, lat + span].join(',')}&layer=mapnik&marker=${lat},${lon}`
  return (
    <div className="map-preview-bubble" style={{ width: PREVIEW_W, height: PREVIEW_H + PREVIEW_TRI_H }}>
      <div className="map-preview-view" style={{ height: PREVIEW_MAP_H }}>
        <iframe src={url} title="Location preview" loading="lazy" style={{ width: '100%', height: '100%', border: 0, pointerEvents: 'none' }} />
      </div>
      <div className="map-preview-info">
        <div className="map-preview-title">{title || 'Location'}</div>
        {region?.trim() && <div className="map-preview-region">{region}</div>}
      </div>
    </div>
  )
}
