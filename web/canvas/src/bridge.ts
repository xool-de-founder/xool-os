// The bridge to Swift (Sources/XoolOS/Xool/Canvas). Page → app: one message
// handler, `xool`. App → page: the functions on `window.XoolCanvas`.
// Outside the app (a browser, for development) the calls go nowhere and
// images stay data URLs, so the page still works on its own.

type Handler = { postMessage(message: unknown): void }

const native: Handler | undefined = (window as any).webkit?.messageHandlers?.xool

let counter = 0
const waiting = new Map<number, (value: any) => void>()

export const inApp = !!native

export function post(message: Record<string, unknown>): void {
  native?.postMessage(message)
}

/** A request the app answers (`XoolCanvas.resolve(id, value)`); `fallback` outside the app. */
export function ask<T>(message: Record<string, unknown>, fallback: T): Promise<T> {
  if (!native) return Promise.resolve(fallback)
  const id = ++counter
  return new Promise<T>(resolve => {
    waiting.set(id, resolve)
    native.postMessage({ ...message, req: id })
    // The app never answers a request it did not understand: don't wait forever.
    setTimeout(() => {
      if (waiting.delete(id)) resolve(fallback)
    }, 15000)
  })
}

export function resolve(id: number, value: unknown): void {
  const done = waiting.get(id)
  if (done) {
    waiting.delete(id)
    done(value)
  }
}

export interface BrainRef {
  id: string
  title: string
  kind: string
}

/** Keeps an image's bytes with the document; returns the address to show it by. */
export async function saveAsset(dataURL: string, name: string): Promise<string> {
  return ask<string>({ type: 'asset', data: dataURL, name }, dataURL)
}

export function searchBrain(query: string): Promise<BrainRef[]> {
  return ask<BrainRef[]>({ type: 'brainSearch', query }, [])
}

export function log(...parts: unknown[]): void {
  post({ type: 'log', text: parts.map(String).join(' ') })
}
