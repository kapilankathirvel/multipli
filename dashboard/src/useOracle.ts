import { useEffect, useState } from 'react'
import { getProvider, type Snapshot } from './data'

export function useOracle(): Snapshot | null {
  const [snap, setSnap] = useState<Snapshot | null>(null)

  useEffect(() => {
    const stop = getProvider().start(setSnap)
    return stop
  }, [])

  return snap
}
