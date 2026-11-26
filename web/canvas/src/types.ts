export type ElType = 'frame' | 'rect' | 'ellipse' | 'line' | 'arrow' | 'text' | 'image' | 'connector'

/** One thing on the surface. Lines and arrows run from (x, y) to (x + w, y + h); w and h may be negative. */
export interface El {
  id: string
  type: ElType
  x: number
  y: number
  w: number
  h: number
  /** A frame's name, shown above it. */
  name?: string
  /** A text element's content: a block document (TipTap / ProseMirror JSON). */
  doc?: any
  /** An image's address. */
  src?: string
  /** A connector's two ends: element ids. */
  from?: string
  to?: string
}

export interface Doc {
  version: 1
  title: string
  view: { x: number; y: number; z: number }
  elements: El[]
}

export const emptyDoc = (): any => ({ type: 'doc', content: [{ type: 'paragraph' }] })

export function newID(): string {
  return Math.random().toString(36).slice(2, 8) + Date.now().toString(36).slice(-3)
}
