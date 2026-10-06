import { lazy, Suspense, useEffect } from 'react'
import { Navigate, Route, Routes, useLocation, useNavigate, useParams } from 'react-router-dom'
import { CenteredSpinner } from '@/components/ui'

const HomeScreen = lazy(() => import('@/screens/HomeScreen'))
const SignInScreen = lazy(() => import('@/screens/SignInScreen'))
const CreateAccountScreen = lazy(() => import('@/screens/CreateAccountScreen'))
const CompleteProfileScreen = lazy(() => import('@/screens/CompleteProfileScreen'))
const FriendsScreen = lazy(() => import('@/screens/FriendsScreen'))
const AboutScreen = lazy(() => import('@/screens/AboutScreen'))
const PremiumScreen = lazy(() => import('@/screens/PremiumScreen'))
const MyTripsScreen = lazy(() => import('@/screens/MyTripsScreen'))
const TripBuilderScreen = lazy(() => import('@/screens/TripBuilderScreen'))
const TripPlanningRoute = lazy(() => import('@/screens/TripPlanningScreen').then((m) => ({ default: m.TripPlanningRoute })))
const VerifiedTripsScreen = lazy(() => import('@/screens/VerifiedTripsScreen'))
const VerifiedTripDetailRoute = lazy(() => import('@/screens/VerifiedTripDetailScreen'))
const VerifiedTripMapScreen = lazy(() => import('@/screens/VerifiedTripMapScreen'))
const AccountScreen = lazy(() => import('@/screens/AccountScreen'))
const AdminPanelScreen = lazy(() => import('@/screens/AdminPanelScreen'))
const AdminTripView = lazy(() => import('@/screens/AdminPanelScreen').then((m) => ({ default: m.AdminTripView })))
const UnlistedPageScreen = lazy(() => import('@/screens/UnlistedPageScreen'))
const UnlistedPageBuilderRoute = lazy(() => import('@/screens/UnlistedPageBuilderScreen'))
const UnlistedPageResponsesScreen = lazy(() => import('@/screens/UnlistedPageResponsesScreen'))
const VerifiedTripBuilderRoute = lazy(() => import('@/screens/VerifiedTripBuilderScreen'))
const TripLinkScreen = lazy(() => import('@/screens/TripLinkScreen'))
const TripDetailRoute = lazy(() => import('@/screens/TripDetailScreen').then((m) => ({ default: m.TripDetailRoute })))

/** Legacy deep links: `/#/trip/...` hash routes and `?joinTrip=users/{uid}/trips/{id}`. */
function LegacyLinkRedirect() {
  const location = useLocation()
  const navigate = useNavigate()
  useEffect(() => {
    const hash = location.hash.replace(/^#/, '')
    if (hash.startsWith('/') && hash.length > 1) {
      navigate(hash, { replace: true })
      return
    }
    const join = new URLSearchParams(location.search).get('joinTrip')?.trim()
    if (join) {
      const parts = join.split('/')
      if (parts.length === 4 && parts[0] === 'users' && parts[2] === 'trips' && parts[1].trim() && parts[3].trim()) {
        navigate(`/trip/${parts[1]}/${parts[3]}`, { replace: true })
      }
    }
  }, [location, navigate])
  return null
}

export default function App() {
  return (
    <Suspense fallback={<CenteredSpinner pad={80} />}>
      <LegacyLinkRedirect />
      <Routes>
        <Route path="/" element={<HomeScreen />} />
        <Route path="/sign-in" element={<SignInScreen />} />
        <Route path="/create-account" element={<CreateAccountScreen />} />
        <Route path="/complete-profile" element={<CompleteProfileScreen />} />
        <Route path="/friends" element={<FriendsScreen />} />
        <Route path="/about" element={<AboutScreen />} />
        <Route path="/premium" element={<PremiumScreen />} />
        <Route path="/verified-trips" element={<VerifiedTripsScreen />} />
        <Route path="/verified-trips/new" element={<VerifiedTripBuilderRoute />} />
        <Route path="/verified-trips/:id/edit" element={<VerifiedTripBuilderRoute />} />
        <Route path="/verified-trips/:id" element={<VerifiedTripDetailRoute />} />
        <Route path="/verified-trips/:id/map" element={<VerifiedTripMapScreen />} />
        <Route path="/account" element={<AccountScreen />} />
        <Route path="/admin" element={<AdminPanelScreen />} />
        <Route path="/admin/trip/:ownerUid/:tripId" element={<AdminTripView />} />
        <Route path="/page/:slug" element={<UnlistedPageScreen />} />
        <Route path="/admin/pages/new" element={<UnlistedPageBuilderRoute />} />
        <Route path="/admin/pages/:slug/edit" element={<UnlistedPageBuilderRoute />} />
        <Route path="/admin/pages/:slug/responses" element={<UnlistedPageResponsesScreen />} />
        <Route path="/plan" element={<TripPlanningRoute />} />
        <Route path="/trip-builder" element={<TripBuilderScreen />} />
        <Route path="/my-trips" element={<MyTripsScreen />} />
        <Route path="/my-trips/:tripId" element={<TripDetailRoute />} />
        <Route path="/trip/:ownerUid/:tripId" element={<TripLinkScreen />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Suspense>
  )
}
void useParams
