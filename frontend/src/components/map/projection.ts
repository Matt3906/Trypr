/** Wraps google.maps.OverlayView to convert lat/lng ↔ container pixels. */
export class ProjectionHelper {
  private view: google.maps.OverlayView
  private ready = false
  constructor(map: google.maps.Map) {
    this.view = new google.maps.OverlayView()
    this.view.onAdd = () => { this.ready = true }
    this.view.draw = () => {}
    this.view.onRemove = () => { this.ready = false }
    this.view.setMap(map)
  }
  toPixel(p: { lat: number; lng: number }): { x: number; y: number } | null {
    const proj = this.view.getProjection()
    if (!this.ready || !proj) return null
    const px = proj.fromLatLngToContainerPixel(new google.maps.LatLng(p.lat, p.lng))
    return px ? { x: px.x, y: px.y } : null
  }
  fromPixel(x: number, y: number): { lat: number; lng: number } | null {
    const proj = this.view.getProjection()
    if (!this.ready || !proj) return null
    const ll = proj.fromContainerPixelToLatLng(new google.maps.Point(x, y))
    return ll ? { lat: ll.lat(), lng: ll.lng() } : null
  }
  dispose() {
    this.view.setMap(null)
  }
}
