import type { ReactNode, CSSProperties } from 'react'
import TopTaskbar from './TopTaskbar'

/** Standard screen: solid taskbar + scrollable body (mirrors Scaffold(appBar: TopTaskbar)). */
export default function PageShell({ children, bodyStyle }: { children: ReactNode; bodyStyle?: CSSProperties }) {
  return (
    <div className="screen">
      <TopTaskbar dockProgress={1} />
      <div className="screen-body" style={bodyStyle}>{children}</div>
    </div>
  )
}
