import { useState } from 'react'
import { MdChevronRight } from 'react-icons/md'
import { cx } from '@/components/ui'

export default function VerifiedTripPreviewCard({ title, subtitle, images, onClick }: { title: string; subtitle: string; images: string[]; onClick?: () => void }) {
  const [idx, setIdx] = useState(0)
  const list = images.length ? images : ['/images/mainScreenPic.jpg']
  const i = idx % list.length
  return (
    <div className={cx('vt-card', onClick && 'clickable')} onClick={onClick} role={onClick ? 'button' : undefined} aria-label={`${title}. ${subtitle}`}>
      <div className="vt-image">
        <img src={list[i]} alt={`Preview image ${i + 1} of ${list.length} for ${title}`} />
        <div className="vt-fade" />
        {list.length > 1 && (
          <button type="button" className="vt-next" title="Next photo" onClick={(e) => { e.stopPropagation(); setIdx((n) => n + 1) }}>
            <MdChevronRight size={20} />
          </button>
        )}
        {list.length > 1 && (
          <div className="vt-dots">
            {list.slice(0, 5).map((_, d) => <span key={d} style={{ width: d === i ? 16 : 6, background: d === i ? '#fff' : 'rgba(255,255,255,.5)' }} />)}
          </div>
        )}
      </div>
      <div className="vt-footer">
        <div className="ellipsis" style={{ fontSize: 14, fontWeight: 600 }}>{title}</div>
        <div className="ellipsis muted" style={{ fontSize: 12, marginTop: 2 }}>{subtitle}</div>
      </div>
    </div>
  )
}
