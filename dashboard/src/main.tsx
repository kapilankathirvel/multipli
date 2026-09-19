import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { getProvider, type MockScriptName } from './data'

// Dev-only hook so the scenarios can be driven from the console before the J3
// buttons exist:  og('s3')  ·  og('reset')  ·  og('warp1h')
if (import.meta.env.DEV) {
  ;(globalThis as unknown as { og: (s: MockScriptName) => void }).og = (s) =>
    getProvider().applyScript(s)
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
