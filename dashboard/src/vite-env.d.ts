/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_MODE?: string
  readonly VITE_RPC_URL?: string
  readonly VITE_MAINNET_RPC_URL?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

declare module '*.json' {
  const value: unknown
  export default value
}
