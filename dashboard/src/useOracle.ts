import { useEffect, useState } from 'react'
import { getProvider, type Snapshot } from './data'

/** The latest snapshot, plus the last read error (cleared by the next good read). */
export function useOracle(): { snap: Snapshot | null; error: string | null } {
  const [snap, setSnap] = useState<Snapshot | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    return getProvider().start(
      (s) => {
        setSnap(s)
        setError(null)
      },
      setError,
    )
  }, [])

  return { snap, error }
}
