import './canvas.css'
import { Engine, type Tool } from './engine'
import { post, resolve } from './bridge'

const stage = document.getElementById('stage')!
const engine = new Engine(stage)

// MARK: chrome — the title, the tools, the zoom

const icons: Record<string, string> = {
  select: '<path d="M4 3l8 4.2-3.4 1.2L7.2 12z" />',
  hand: '<path d="M5.5 8V4.2a1 1 0 012 0V7m0-3.3a1 1 0 012 0V7m0-2.3a1 1 0 012 0V8m0-1.2a1 1 0 012 0V10c0 2.4-1.6 4-4 4H8c-1.6 0-2.4-.8-3.2-2L3.3 9.6a1 1 0 011.6-1.2z" />',
  frame: '<path d="M4.5 2v12M11.5 2v12M2 4.5h12M2 11.5h12" />',
  rect: '<rect x="2.5" y="3.5" width="11" height="9" rx="1.5" />',
  ellipse: '<ellipse cx="8" cy="8" rx="5.5" ry="4.5" />',
  line: '<path d="M3 13L13 3" />',
  arrow: '<path d="M3 13L13 3M7 3h6v6" />',
  text: '<path d="M3.5 4V3h9v1M8 3v10M6 13h4" />',
  connector: '<circle cx="3.5" cy="12.5" r="1.6" /><circle cx="12.5" cy="3.5" r="1.6" /><path d="M5 11.2C8 10 8 6 11 4.8" />',
  image: '<rect x="2.5" y="3" width="11" height="10" rx="1.5" /><circle cx="6" cy="6.5" r="1" /><path d="M3 12l3.5-3.5L9 11l2-2 2.5 2.5" />',
}
const toolList: [Tool | 'image', string, string][] = [
  ['select', 'Select', 'V'], ['hand', 'Hand', 'H'], ['frame', 'Frame', 'F'], ['rect', 'Rectangle', 'R'], ['ellipse', 'Ellipse', 'O'],
  ['line', 'Line', 'L'], ['arrow', 'Arrow', 'A'], ['text', 'Text', 'T'], ['connector', 'Connector', 'C'], ['image', 'Image', ''],
]
const icon = (name: string) => `<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${icons[name]}</svg>`

const bar = document.getElementById('tools')!
const buttons = new Map<string, HTMLButtonElement>()
for (const [name, label, key] of toolList) {
  if (name === 'image') {
    const sep = document.createElement('span')
    sep.className = 'sep'
    bar.append(sep)
  }
  const b = document.createElement('button')
  b.type = 'button'
  b.innerHTML = icon(name)
  b.title = key ? `${label} (${key})` : label
  b.setAttribute('aria-label', label)
  b.addEventListener('click', () => {
    if (name === 'image') {
      const input = document.createElement('input')
      input.type = 'file'
      input.accept = 'image/*'
      input.multiple = true
      input.addEventListener('change', () => [...(input.files ?? [])].forEach(f => engine.addImageFile(f)))
      input.click()
    } else engine.setTool(name as Tool)
  })
  bar.append(b)
  buttons.set(name, b)
}
engine.onTool = tool => buttons.forEach((b, name) => b.setAttribute('aria-pressed', String(name === tool)))
engine.onTool('select')

const zoomLabel = document.getElementById('zoom-level') as HTMLButtonElement
engine.onZoom = z => { zoomLabel.textContent = Math.round(z * 100) + '%' }
engine.setZoom(1)
document.getElementById('zoom-in')!.addEventListener('click', () => engine.setZoom(engine.view.z * 1.25))
document.getElementById('zoom-out')!.addEventListener('click', () => engine.setZoom(engine.view.z / 1.25))
zoomLabel.addEventListener('click', () => engine.setZoom(1))
document.getElementById('zoom-fit')!.addEventListener('click', () => engine.fitAndSave())

const title = document.getElementById('title') as HTMLInputElement
title.addEventListener('input', () => { engine.title = title.value; engine.scheduleSave(); post({ type: 'title', title: title.value }) })
title.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === 'Escape') title.blur() })
title.addEventListener('blur', () => { if (!title.value.trim()) { title.value = 'Untitled canvas'; engine.title = title.value; engine.scheduleSave(); post({ type: 'title', title: title.value }) } })

const hint = document.getElementById('hint')!
engine.onChange = empty => { hint.hidden = !empty }

// MARK: what the app calls

const api = {
  load(json: string | null) {
    engine.load(json)
    title.value = engine.title
  },
  replace(json: string) {
    engine.replace(json)
    title.value = engine.title
  },
  setTitle(text: string) { engine.title = text; title.value = text },
  setTheme(vars: Record<string, string>) {
    const root = document.documentElement
    for (const [k, v] of Object.entries(vars)) root.style.setProperty('--' + k, v)
    root.style.colorScheme = vars['scheme'] === 'dark' ? 'dark' : 'light'
  },
  resolve,
  flush() { engine.flush() },
  /** Test runs: the surface as the page sees it. */
  inspect() { return { elements: engine.els, selected: [...engine.sel], view: engine.view, tool: engine.tool, title: engine.title } },
  engine,
}
;(window as any).XoolCanvas = api

post({ type: 'ready' })
