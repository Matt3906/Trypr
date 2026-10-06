import {StrictMode} from 'react'
import {createRoot} from 'react-dom/client'
import {BrowserRouter} from 'react-router-dom'
import App from './App'
import {AuthProvider} from './context/Auth'
import {FeedbackProvider} from './context/Feedback'
import './styles/global.css'
import './styles/home.css'
import './styles/map.css'
import './styles/tripDetail.css'
import './styles/tripBuilder.css'
import './styles/planning.css'
import './styles/pages.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter>
      <FeedbackProvider>
        <AuthProvider>
          <App />
        </AuthProvider>
      </FeedbackProvider>
    </BrowserRouter>
  </StrictMode>,
)
