import { signOut } from '@/backend/auth'
import { MdMenu, MdPersonOutline } from 'react-icons/md'
import { useNavigate } from 'react-router-dom'
import { auth } from '@/backend'
import { useAuth } from '@/context/Auth'
import { useFeedback } from '@/context/Feedback'
import { cx, Menu, MenuDivider, MenuItem } from './ui'

/** Linear interpolate between two rgb triples. */
const lerpColor = (a: [number, number, number], b: [number, number, number], t: number) =>
  `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * t)).join(',')})`

/**
 * Top navigation bar. `dockProgress` goes 0→1 as the page scrolls: transparent with
 * white text at 0, solid white with dark text at 1.
 */
export default function TopTaskbar({ dockProgress = 1, overlay = false }: { dockProgress?: number; overlay?: boolean }) {
  const dp = Math.min(1, Math.max(0, dockProgress))
  const navigate = useNavigate()
  const { signedIn, isAdmin, isPremium, userData } = useAuth()
  const { toast } = useFeedback()

  const navColor = lerpColor([255, 255, 255], [47, 42, 38], dp)
  const adminColor = lerpColor([0, 184, 148], [0, 137, 111], dp)
  const avatarImg: string | undefined = userData?.profileImageDataUrl

  const go = (p: string) => () => navigate(p)

  const items: { label: string; path: string }[] = [
    { label: 'My Trips', path: '/my-trips' },
    { label: 'Trip Builder', path: '/trip-builder' },
    { label: 'Verified Trips', path: '/verified-trips' },
    { label: 'About', path: '/about' },
  ]

  const doSignOut = async (close: () => void) => {
    close()
    try {
      await signOut(auth)
    } catch {
      /* ignore */
    }
    navigate('/', { replace: true })
    toast('Signed out')
  }

  return (
    <header
      className={cx('taskbar', overlay && 'transparent')}
      style={{
        background: `rgba(255,255,255,${0.62 * dp})`,
        WebkitBackdropFilter: dp > 0.02 ? `blur(${22 * dp}px) saturate(180%)` : undefined,
        backdropFilter: dp > 0.02 ? `blur(${22 * dp}px) saturate(180%)` : undefined,
        borderBottom: `1px solid rgba(255,255,255,${0.8 * dp})`,
        boxShadow: dp > 0.9 ? 'inset 0 -1px 0 rgba(42, 32, 26,0.04), 0 8px 28px rgba(74, 56, 40,0.08)' : undefined,
      }}
    >
      <img
        src="/images/TryprLogo.png"
        alt="Trypr"
        className="logo"
        style={{ height: 52, width: 'auto', cursor: 'pointer', filter: 'drop-shadow(0 3px 6px rgba(74,48,30,0.22))' }}
        onClick={() => navigate('/')}
      />

      <nav className="hide-mobile grow row" style={{ overflowX: 'auto' }}>
        {items.map((i) => (
          <button key={i.path} className="nav-item" style={{ color: dp < 0.5 ? 'rgba(255,255,255,0.85)' : navColor }} onClick={go(i.path)}>
            {i.label}
          </button>
        ))}
        {isAdmin && (
          <button className="nav-item" style={{ color: adminColor }} onClick={go('/admin')}>
            ⚙️ Admin
          </button>
        )}
      </nav>

      <div className="hide-desktop grow" />
      <div className="hide-desktop">
        <Menu
          trigger={
            <button className="icon-btn" aria-label="Menu" style={{ color: navColor }}>
              <MdMenu size={24} />
            </button>
          }
        >
          {(close) => (
            <>
              {items.map((i) => (
                <MenuItem key={i.path} onClick={() => { close(); navigate(i.path) }}>{i.label}</MenuItem>
              ))}
              {isAdmin && (
                <MenuItem color="#00b894" onClick={() => { close(); navigate('/admin') }}>⚙️ Admin Panel</MenuItem>
              )}
            </>
          )}
        </Menu>
      </div>

      <Menu
        trigger={
          <button className="avatar-btn" title="Account" style={{ background: dp < 0.5 ? 'rgba(255,255,255,0.24)' : 'var(--glass-bg)', color: navColor }}>
            {avatarImg ? <img src={avatarImg} alt="" /> : <MdPersonOutline size={22} />}
          </button>
        }
      >
        {(close) =>
          signedIn ? (
            <>
              <MenuItem onClick={() => { close(); navigate('/account') }}>View account</MenuItem>
              <MenuItem onClick={() => { close(); navigate('/friends') }}>Friends</MenuItem>
              <MenuItem onClick={() => { close(); navigate('/premium') }}>{isPremium ? 'Manage Premium' : 'Unlock Premium'}</MenuItem>
              <MenuDivider />
              <MenuItem onClick={() => doSignOut(close)}>Sign out</MenuItem>
            </>
          ) : (
            <>
              <MenuItem onClick={() => { close(); navigate('/sign-in') }}>Sign in</MenuItem>
              <MenuItem onClick={() => { close(); navigate('/create-account') }}>Create account</MenuItem>
            </>
          )
        }
      </Menu>
    </header>
  )
}
