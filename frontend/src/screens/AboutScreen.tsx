import { MdExplore } from 'react-icons/md'
import { useNavigate } from 'react-router-dom'
import PageShell from '@/components/PageShell'
import { Button } from '@/components/ui'

export default function AboutScreen() {
  const navigate = useNavigate()
  return (
    <PageShell>
      <div className="container col gap-md">
        <div className="center" style={{ paddingBottom: 12 }}>
          <img src="/images/TryprLogo_Black.png" alt="Trypr" style={{ height: 96, objectFit: 'contain', maxWidth: '100%' }} />
        </div>
        <h2 className="t-title-l" style={{ fontWeight: 700 }}>Plan deeper. Travel smarter.</h2>

        <div className="about-grid">
          <div className="col gap-sm">
            <div
              style={{
                height: 320, borderRadius: 12, boxShadow: '0 6px 12px rgba(0,0,0,.08)',
                backgroundColor: '#f5f5f5', backgroundImage: 'url(/images/aboutUsPic.jpg)', backgroundSize: 'cover', backgroundPosition: 'center',
              }}
              className="about-img"
            />
            <div style={{ textAlign: 'center', fontStyle: 'italic', color: 'rgba(0,0,0,.54)' }}>
              McDonald Lake, Glacier National Park - Apgar, Montana
            </div>
          </div>
          <div className="col gap-sm">
            <h3 style={{ fontSize: 15, fontWeight: 700 }}>About Trypr</h3>
            <p>
              Trypr is a trip planning home built for people who love planning — not just point‑A to point‑B navigation. When
              traditional map tools fall short for ambitious roadtrip planning, Trypr steps in with a planner designed for real
              trips: rigorous route control, group collaboration, and the tools you need to actually get ready and go.
            </p>
          </div>
        </div>

        <h3 style={{ fontSize: 14, fontWeight: 600, marginTop: 8 }}>What Trypr does</h3>
        <div className="col" style={{ gap: 4 }}>
          <div>• Focused, detailed roadtrip planning (car).</div>
          <div>• Collaborative trips — invite friends, edit together, and keep everyone in sync.</div>
          <div>• Shared packing lists with collaboration so nobody forgets the essentials.</div>
          <div>• Live trip features: group chat, effortless photo sharing, and plans to support full-resolution images without heavy compression.</div>
        </div>

        <h3 style={{ fontSize: 14, fontWeight: 600, marginTop: 8 }}>Future modes</h3>
        <p>
          Soon we’ll expand beyond roadtrips to support hiking/backpacking, equestrian routes, portaging, and bikepacking —
          because different adventures need different tools.
        </p>

        <h3 style={{ fontSize: 14, fontWeight: 600, marginTop: 8 }}>Why I built it</h3>
        <p>
          I’m a 19‑year‑old from Toronto who loves to travel and to plan. Spreadsheets and generic map apps weren’t cutting it
          for the kinds of trips I wanted to build, so I made something better — a “mega” trip planning home for planners who
          take their trips seriously.
        </p>

        <div style={{ marginTop: 12 }}>
          <Button variant="solid" icon={<MdExplore size={18} />} onClick={() => navigate('/trip-builder')}>Start planning a trip</Button>
        </div>
        <p className="t-body-s" style={{ textAlign: 'center', marginTop: 12 }}>
          Built with care in Toronto. © {new Date().getFullYear()} Trypr
        </p>
      </div>
    </PageShell>
  )
}
