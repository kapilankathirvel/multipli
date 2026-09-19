import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { getRunner, type ScenarioId } from './scenarios'

// Dev-only hook to drive the scenarios from the console:  og('s3')  ·  og('reset')
if (import.meta.env.DEV) {
  ;(globalThis as unknown as { og: (s: ScenarioId) => Promise<string> }).og = (s) =>
    getRunner().run(s)
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
