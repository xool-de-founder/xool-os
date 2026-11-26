// The surface: an endless plane with frames, shapes, lines, text blocks,
// pictures and connectors. Zoom and pan are one transform on `world`; every
// element is a node in it, drawn with HTML and SVG (no canvas bitmap, so
// text stays sharp at any zoom). Selection handles live in screen space on
// top (`ui`), so they keep their size when you zoom.

import type { Editor } from '@tiptap/core'
import { type Doc, type El, type ElType, emptyDoc, newID } from './types'
import { closeMenus, isEmptyDoc, menuOpen, open as openLink, openEditor, readAsDataURL, renderDoc } from './editor'
import { post, saveAsset } from './bridge'

export type Tool = 'select' | 'hand' | 'frame' | 'rect' | 'ellipse' | 'line' | 'arrow' | 'text' | 'connector'

const SVG = 'http://www.w3.org/2000/svg'
const MIN_ZOOM = 0.1
const MAX_ZOOM = 4

type Box = { x: number; y: number; w: number; h: number }
type Point = { x: number; y: number }

function norm(el: El): Box {
  return { x: Math.min(el.x, el.x + el.w), y: Math.min(el.y, el.y + el.h), w: Math.abs(el.w), h: Math.abs(el.h) }
}

function union(boxes: Box[]): Box | null {
  if (!boxes.length) return null
  const x0 = Math.min(...boxes.map(b => b.x)), y0 = Math.min(...boxes.map(b => b.y))
  const x1 = Math.max(...boxes.map(b => b.x + b.w)), y1 = Math.max(...boxes.map(b => b.y + b.h))
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
}

function edgePoint(b: Box, toward: Point): Point {
  const cx = b.x + b.w / 2, cy = b.y + b.h / 2
  const dx = toward.x - cx, dy = toward.y - cy
  if (dx === 0 && dy === 0) return { x: cx, y: cy }
  const k = Math.min(b.w / 2 / (Math.abs(dx) || 1e-9), b.h / 2 / (Math.abs(dy) || 1e-9))
  return { x: cx + dx * k, y: cy + dy * k }
}

type Gesture =
  | { kind: 'pan'; sx: number; sy: number; vx: number; vy: number }
  | { kind: 'move'; start: Point; origin: Map<string, Point>; moved: boolean }
  | { kind: 'resize'; dir: string; start: Point; orig: Box; id: string; origEl: El }
  | { kind: 'marquee'; start: Point; base: Set<string> }
  | { kind: 'create'; tool: Tool; start: Point; el: El | null }
  | { kind: 'connect'; from: string; start: Point }

export class Engine {
  readonly stage: HTMLElement
  private world = document.createElement('div')
  private connectors = document.createElementNS(SVG, 'svg')
  private ui = document.createElement('div')
  private marqueeBox = document.createElement('div')
  private preview = document.createElementNS(SVG, 'svg')

  els: El[] = []
  title = 'Untitled canvas'
  view = { x: 80, y: 80, z: 1 }
  sel = new Set<string>()
  tool: Tool = 'select'

  private nodes = new Map<string, HTMLElement>()
  private shown = new Map<string, string>()
  private editing: { id: string; editor: Editor } | null = null
  private history: string[] = []
  private at = -1
  private gesture: Gesture | null = null
  private spaceDown = false
  private saveTimer = 0
  private commitTimer = 0
  /** Set once the person has moved the view or the content by hand: no more fitting on its own. */
  private touched = false

  onTool: (tool: Tool) => void = () => {}
  onZoom: (z: number) => void = () => {}
  onChange: (empty: boolean) => void = () => {}

  constructor(stage: HTMLElement) {
    this.stage = stage
    this.world.className = 'world'
    this.connectors.setAttribute('class', 'connectors')
    this.ui.className = 'ui'
    this.marqueeBox.className = 'marquee'
    this.marqueeBox.hidden = true
    this.preview.setAttribute('class', 'preview')
    this.world.append(this.connectors)
    stage.append(this.world, this.ui, this.marqueeBox, this.preview)
    this.listen()
    this.applyView()
    this.reset([])
  }

  // MARK: document

  toDoc(): Doc {
    return { version: 1, title: this.title, view: { ...this.view }, elements: this.els }
  }

  load(raw: string | null) {
    this.endEdit(false)
    this.touched = false
    let doc: Partial<Doc> = {}
    try { doc = raw ? JSON.parse(raw) : {} } catch { doc = {} }
    this.title = doc.title || 'Untitled canvas'
    this.reset(Array.isArray(doc.elements) ? doc.elements : [])
    if (doc.view && isFinite(doc.view.z)) this.view = { ...doc.view }
    else {
      this.fit()
      // The page may not have its size yet: once more when it has.
      requestAnimationFrame(() => requestAnimationFrame(() => { if (!this.touched) this.fit() }))
    }
    this.applyView()
    this.render()
  }

  /** The app changed the document (an agent added to it): take its elements, keep the view, let Undo step back. */
  replace(raw: string) {
    this.endEdit(false)
    try {
      const doc = JSON.parse(raw) as Doc
      this.els = doc.elements ?? []
      if (doc.title) this.title = doc.title
    } catch { return }
    this.sel = new Set([...this.sel].filter(id => this.els.some(e => e.id === id)))
    this.push()
    this.render()
  }

  private reset(els: El[]) {
    this.els = els
    this.sel.clear()
    this.history = [JSON.stringify(els)]
    this.at = 0
    this.render()
  }

  private snapshot() { return JSON.stringify(this.els) }

  /** A finished change: one step for Undo, and the document is kept. */
  commit() {
    this.push()
    this.render()
  }

  private push() {
    this.touched = true
    const snap = this.snapshot()
    if (snap !== this.history[this.at]) {
      this.history = this.history.slice(0, this.at + 1)
      this.history.push(snap)
      if (this.history.length > 200) this.history.shift()
      this.at = this.history.length - 1
    }
    this.scheduleSave()
  }

  undo() {
    if (this.editing) return
    if (this.at <= 0) return
    this.at -= 1
    this.restore()
  }

  redo() {
    if (this.editing) return
    if (this.at >= this.history.length - 1) return
    this.at += 1
    this.restore()
  }

  private restore() {
    this.els = JSON.parse(this.history[this.at])
    this.sel = new Set([...this.sel].filter(id => this.els.some(e => e.id === id)))
    this.render()
    this.scheduleSave()
  }

  scheduleSave() {
    clearTimeout(this.saveTimer)
    this.saveTimer = window.setTimeout(() => this.flush(), 500)
  }

  flush() {
    clearTimeout(this.saveTimer)
    this.endEditSilently()
    post({ type: 'save', json: JSON.stringify(this.toDoc()) })
  }

  private endEditSilently() {
    const el = this.editing && this.els.find(e => e.id === this.editing!.id)
    if (el && this.editing) el.doc = this.editing.editor.getJSON()
  }

  // MARK: view

  private applyView() {
    const { x, y, z } = this.view
    this.world.style.transform = `translate(${x}px, ${y}px) scale(${z})`
    const step = 24 * z
    this.stage.style.backgroundSize = `${step}px ${step}px`
    this.stage.style.backgroundPosition = `${x}px ${y}px`
    this.stage.classList.toggle('no-grid', z < 0.35)
    this.onZoom(z)
    this.drawUI()
  }

  setZoom(z: number, around?: Point) {
    this.touched = true
    const rect = this.stage.getBoundingClientRect()
    const cx = around ? around.x : rect.width / 2
    const cy = around ? around.y : rect.height / 2
    const next = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z))
    const k = next / this.view.z
    this.view = { x: cx - (cx - this.view.x) * k, y: cy - (cy - this.view.y) * k, z: next }
    this.applyView()
    this.scheduleSave()
  }

  fit() {
    const rect = this.stage.getBoundingClientRect()
    const bounds = union(this.els.filter(e => e.type !== 'connector').map(norm))
    if (!bounds || rect.width === 0) { this.view = { x: 80, y: 80, z: 1 }; return }
    const pad = 80
    const z = Math.min(1, Math.max(MIN_ZOOM, Math.min((rect.width - pad * 2) / Math.max(1, bounds.w), (rect.height - pad * 2) / Math.max(1, bounds.h))))
    this.view = { z, x: (rect.width - bounds.w * z) / 2 - bounds.x * z, y: (rect.height - bounds.h * z) / 2 - bounds.y * z }
    this.applyView()
  }

  fitAndSave() { this.fit(); this.scheduleSave() }

  private toWorld(clientX: number, clientY: number): Point {
    const rect = this.stage.getBoundingClientRect()
    return { x: (clientX - rect.left - this.view.x) / this.view.z, y: (clientY - rect.top - this.view.y) / this.view.z }
  }

  private toScreen(p: Point): Point {
    return { x: p.x * this.view.z + this.view.x, y: p.y * this.view.z + this.view.y }
  }

  centre(): Point {
    const rect = this.stage.getBoundingClientRect()
    return this.toWorld(rect.left + rect.width / 2, rect.top + rect.height / 2)
  }

  // MARK: tools

  setTool(tool: Tool) {
    if (this.editing) this.endEdit()
    this.tool = tool
    this.stage.dataset.tool = tool
    this.onTool(tool)
    if (tool !== 'select') { this.sel.clear(); this.drawUI() }
  }

  // MARK: rendering

  private z(el: El, index: number) { return el.type === 'frame' ? index : 10000 + index }

  render() {
    const live = new Set(this.els.map(e => e.id))
    for (const [id, node] of this.nodes) {
      if (!live.has(id)) { node.remove(); this.nodes.delete(id); this.shown.delete(id) }
    }
    this.els.forEach((el, index) => {
      if (el.type === 'connector') return
      let node = this.nodes.get(el.id)
      if (!node) {
        node = this.make(el)
        this.nodes.set(el.id, node)
        this.world.append(node)
      }
      this.place(el, node, index)
    })
    this.drawConnectors()
    this.drawUI()
    this.onChange(this.els.length === 0)
  }

  private make(el: El): HTMLElement {
    const node = document.createElement(el.type === 'line' || el.type === 'arrow' ? 'div' : 'div')
    node.dataset.id = el.id
    node.className = 'el ' + el.type
    switch (el.type) {
      case 'frame': {
        const label = document.createElement('div')
        label.className = 'frame-label'
        node.append(label)
        for (const side of ['n', 'e', 's', 'w']) {
          const edge = document.createElement('div')
          edge.className = 'edge ' + side
          node.append(edge)
        }
        break
      }
      case 'text': {
        const content = document.createElement('div')
        content.className = 'content'
        node.append(content)
        break
      }
      case 'image': {
        const img = document.createElement('img')
        img.draggable = false
        img.alt = el.name || 'Image'
        node.append(img)
        break
      }
      case 'line':
      case 'arrow': {
        const svg = document.createElementNS(SVG, 'svg')
        svg.setAttribute('class', 'stroke')
        const hit = document.createElementNS(SVG, 'path')
        hit.setAttribute('class', 'hit')
        const line = document.createElementNS(SVG, 'path')
        line.setAttribute('class', 'ink')
        const head = document.createElementNS(SVG, 'path')
        head.setAttribute('class', 'head')
        svg.append(hit, line, head)
        node.append(svg)
        break
      }
    }
    return node
  }

  private place(el: El, node: HTMLElement, index: number) {
    node.style.zIndex = String(this.z(el, index))
    const b = norm(el)
    node.classList.toggle('selected', this.sel.has(el.id))
    if (el.type === 'line' || el.type === 'arrow') {
      node.style.left = el.x + 'px'
      node.style.top = el.y + 'px'
      const d = `M0 0 L${el.w} ${el.h}`
      const paths = node.querySelectorAll('path')
      paths[0].setAttribute('d', d)
      paths[1].setAttribute('d', d)
      if (el.type === 'arrow') {
        const len = Math.hypot(el.w, el.h) || 1
        const ux = el.w / len, uy = el.h / len
        const s = 12
        const bx = el.w - ux * s, by = el.h - uy * s
        paths[2].setAttribute('d', `M${bx - uy * s * 0.5} ${by + ux * s * 0.5} L${el.w} ${el.h} L${bx + uy * s * 0.5} ${by - ux * s * 0.5}`)
      } else {
        paths[2].setAttribute('d', '')
      }
      return
    }
    node.style.left = b.x + 'px'
    node.style.top = b.y + 'px'
    node.style.width = b.w + 'px'
    if (el.type !== 'text') node.style.height = b.h + 'px'
    if (el.type === 'frame') {
      ;(node.querySelector('.frame-label') as HTMLElement).textContent = el.name || 'Frame'
    } else if (el.type === 'image') {
      const img = node.querySelector('img') as HTMLImageElement
      if (img.getAttribute('src') !== el.src) img.src = el.src || ''
    } else if (el.type === 'text') {
      const content = node.querySelector('.content') as HTMLElement
      if (this.editing?.id !== el.id) {
        const key = JSON.stringify(el.doc ?? null)
        if (this.shown.get(el.id) !== key) {
          this.shown.set(el.id, key)
          const empty = isEmptyDoc(el.doc)
          content.innerHTML = empty ? '' : renderDoc(el.doc)
          node.classList.toggle('empty', empty)
        }
      }
      // A text block is as tall as its content.
      node.style.height = 'auto'
      const h = Math.max(24, node.offsetHeight)
      if (Math.abs(h - el.h) > 0.5) el.h = h
    }
  }

  private drawConnectors() {
    const svg = this.connectors
    const wanted = this.els.filter(e => e.type === 'connector')
    svg.replaceChildren()
    for (const c of wanted) {
      const a = this.els.find(e => e.id === c.from), b = this.els.find(e => e.id === c.to)
      if (!a || !b) continue
      const ba = norm(a), bb = norm(b)
      const ca = { x: ba.x + ba.w / 2, y: ba.y + ba.h / 2 }, cb = { x: bb.x + bb.w / 2, y: bb.y + bb.h / 2 }
      const p = edgePoint(ba, cb), q = edgePoint(bb, ca)
      const g = document.createElementNS(SVG, 'g')
      g.setAttribute('data-id', c.id)
      g.setAttribute('class', 'connector' + (this.sel.has(c.id) ? ' selected' : ''))
      const hit = document.createElementNS(SVG, 'path')
      hit.setAttribute('class', 'hit')
      hit.setAttribute('d', `M${p.x} ${p.y} L${q.x} ${q.y}`)
      const ink = document.createElementNS(SVG, 'path')
      ink.setAttribute('class', 'ink')
      ink.setAttribute('d', `M${p.x} ${p.y} L${q.x} ${q.y}`)
      const head = document.createElementNS(SVG, 'path')
      head.setAttribute('class', 'head')
      const len = Math.hypot(q.x - p.x, q.y - p.y) || 1
      const ux = (q.x - p.x) / len, uy = (q.y - p.y) / len
      const bx = q.x - ux * 10, by = q.y - uy * 10
      head.setAttribute('d', `M${bx - uy * 5} ${by + ux * 5} L${q.x} ${q.y} L${bx + uy * 5} ${by - ux * 5}`)
      g.append(hit, ink, head)
      svg.append(g)
    }
  }

  // MARK: selection UI

  private bounds(ids: Iterable<string>): Box | null {
    return union([...ids].map(id => this.els.find(e => e.id === id)).filter((e): e is El => !!e && e.type !== 'connector').map(norm))
  }

  private drawUI() {
    this.ui.replaceChildren()
    for (const node of this.nodes.values()) node.classList.toggle('selected', this.sel.has(node.dataset.id!))
    this.connectors.querySelectorAll('.connector').forEach(g => g.classList.toggle('selected', this.sel.has(g.getAttribute('data-id')!)))
    if (this.editing || this.sel.size === 0) return
    const only = this.sel.size === 1 ? this.els.find(e => e.id === [...this.sel][0]) : undefined
    if (only?.type === 'connector') return
    const box = this.bounds(this.sel)
    if (!box) return
    const a = this.toScreen({ x: box.x, y: box.y }), z = this.view.z
    const outline = document.createElement('div')
    outline.className = 'outline'
    Object.assign(outline.style, { left: a.x + 'px', top: a.y + 'px', width: box.w * z + 'px', height: box.h * z + 'px' })
    if (only && (only.type === 'line' || only.type === 'arrow')) outline.style.display = 'none'
    this.ui.append(outline)
    const handle = (name: string, sx: number, sy: number, label: string) => {
      const h = document.createElement('div')
      h.className = 'handle'
      h.dataset.handle = name
      h.setAttribute('aria-label', label)
      Object.assign(h.style, { left: sx + 'px', top: sy + 'px', cursor: this.cursorFor(name) })
      this.ui.append(h)
    }
    if (only && (only.type === 'line' || only.type === 'arrow')) {
      const p1 = this.toScreen({ x: only.x, y: only.y }), p2 = this.toScreen({ x: only.x + only.w, y: only.y + only.h })
      handle('p1', p1.x, p1.y, 'Start')
      handle('p2', p2.x, p2.y, 'End')
      return
    }
    if (!only) return
    const x0 = a.x, y0 = a.y, x1 = a.x + box.w * z, y1 = a.y + box.h * z, mx = (x0 + x1) / 2, my = (y0 + y1) / 2
    if (only.type === 'text') {
      handle('e', x1, my, 'Resize width'); handle('w', x0, my, 'Resize width')
      return
    }
    handle('nw', x0, y0, 'Resize'); handle('n', mx, y0, 'Resize'); handle('ne', x1, y0, 'Resize')
    handle('e', x1, my, 'Resize'); handle('se', x1, y1, 'Resize'); handle('s', mx, y1, 'Resize')
    handle('sw', x0, y1, 'Resize'); handle('w', x0, my, 'Resize')
  }

  private cursorFor(dir: string): string {
    return ({ n: 'ns-resize', s: 'ns-resize', e: 'ew-resize', w: 'ew-resize', nw: 'nwse-resize', se: 'nwse-resize', ne: 'nesw-resize', sw: 'nesw-resize', p1: 'crosshair', p2: 'crosshair' } as Record<string, string>)[dir] || 'default'
  }

  // MARK: elements

  find(id: string) { return this.els.find(e => e.id === id) }

  add(el: El): El {
    this.els.push(el)
    return el
  }

  private makeEl(type: ElType, at: Point): El {
    const base = { id: newID(), type, x: at.x, y: at.y, w: 0, h: 0 }
    if (type === 'frame') return { ...base, name: `Frame ${this.els.filter(e => e.type === 'frame').length + 1}`, w: 480, h: 320 }
    if (type === 'rect' || type === 'ellipse') return { ...base, w: 140, h: 100 }
    if (type === 'line' || type === 'arrow') return { ...base, w: 140, h: 0 }
    if (type === 'text') return { ...base, w: 260, h: 32, doc: emptyDoc() }
    return { ...base, w: 200, h: 140 }
  }

  /** Elements whose centre lies inside a frame: they travel with it. */
  private inside(frame: El): El[] {
    const b = norm(frame)
    return this.els.filter(e => {
      if (e.id === frame.id || e.type === 'connector') return false
      const n = norm(e)
      const cx = n.x + n.w / 2, cy = n.y + n.h / 2
      return cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h
    })
  }

  selectOnly(id: string | null) {
    this.sel = new Set(id ? [id] : [])
    this.drawUI()
  }

  remove() {
    if (!this.sel.size) return
    const gone = new Set(this.sel)
    this.els = this.els.filter(e => !gone.has(e.id) && !(e.type === 'connector' && (gone.has(e.from!) || gone.has(e.to!))))
    this.sel.clear()
    this.commit()
  }

  duplicate() {
    if (!this.sel.size) return
    const map = new Map<string, string>()
    const copies: El[] = []
    for (const e of this.els) {
      if (!this.sel.has(e.id) || e.type === 'connector') continue
      const c = JSON.parse(JSON.stringify(e)) as El
      c.id = newID(); c.x += 24; c.y += 24
      map.set(e.id, c.id)
      copies.push(c)
    }
    for (const e of this.els) {
      if (e.type === 'connector' && map.has(e.from!) && map.has(e.to!)) copies.push({ ...e, id: newID(), from: map.get(e.from!), to: map.get(e.to!) })
    }
    this.els.push(...copies)
    this.sel = new Set(copies.filter(c => c.type !== 'connector').map(c => c.id))
    this.commit()
  }

  order(toFront: boolean) {
    if (!this.sel.size) return
    const chosen = this.els.filter(e => this.sel.has(e.id)), rest = this.els.filter(e => !this.sel.has(e.id))
    this.els = toFront ? [...rest, ...chosen] : [...chosen, ...rest]
    this.commit()
  }

  nudge(dx: number, dy: number) {
    if (!this.sel.size) return
    for (const e of this.els) if (this.sel.has(e.id)) { e.x += dx; e.y += dy }
    this.render()
    clearTimeout(this.commitTimer)
    this.commitTimer = window.setTimeout(() => this.commit(), 400)
  }

  selectAll() {
    this.sel = new Set(this.els.filter(e => e.type !== 'connector').map(e => e.id))
    this.drawUI()
  }

  // MARK: editing a text element

  startEdit(id: string) {
    const el = this.find(id)
    const node = this.nodes.get(id)
    if (!el || el.type !== 'text' || !node) return
    this.endEdit()
    const content = node.querySelector('.content') as HTMLElement
    content.innerHTML = ''
    node.classList.add('editing')
    node.classList.remove('empty')
    this.sel = new Set([id])
    const editor = openEditor(content, el.doc ?? emptyDoc(), () => {
      el.doc = editor.getJSON()
      this.place(el, node, this.els.indexOf(el))
      this.scheduleSave()
    })
    this.editing = { id, editor }
    this.drawUI()
    node.addEventListener('focusout', event => {
      const to = (event as FocusEvent).relatedTarget as HTMLElement | null
      if (to && (node.contains(to) || to.closest?.('.popup'))) return
      window.setTimeout(() => {
        const now = document.activeElement as HTMLElement | null
        if (this.editing?.id !== id || menuOpen() || node.contains(now) || now?.closest?.('.popup')) return
        this.endEdit()
      }, 0)
    })
  }

  endEdit(commit = true) {
    const current = this.editing
    if (!current) return
    this.editing = null
    const el = this.find(current.id)
    const node = this.nodes.get(current.id)
    if (el) el.doc = current.editor.getJSON()
    current.editor.destroy()
    closeMenus()
    node?.classList.remove('editing')
    if (el) this.shown.delete(el.id)
    // A text block left empty is not kept.
    if (el && isEmptyDoc(el.doc)) {
      this.els = this.els.filter(e => e.id !== el.id)
      this.sel.delete(el.id)
    }
    if (commit) this.commit()
    else this.render()
  }

  private renameFrame(id: string) {
    const el = this.find(id), node = this.nodes.get(id)
    if (!el || !node) return
    const label = node.querySelector('.frame-label') as HTMLElement
    const input = document.createElement('input')
    input.className = 'frame-name'
    input.value = el.name || ''
    input.setAttribute('aria-label', 'Frame name')
    label.replaceChildren(input)
    input.focus()
    input.select()
    let done = false
    const finish = (keep: boolean) => {
      if (done) return
      done = true
      if (keep && input.value.trim()) { el.name = input.value.trim(); this.commit() } else this.render()
      label.textContent = el.name || 'Frame'
    }
    input.addEventListener('keydown', e => {
      e.stopPropagation()
      if (e.key === 'Enter') finish(true)
      if (e.key === 'Escape') finish(false)
    })
    input.addEventListener('blur', () => finish(true))
  }

  // MARK: pictures

  async addImageFile(file: File, at?: Point) {
    let data = await readAsDataURL(file)
    const probe = await new Promise<HTMLImageElement>((resolve, reject) => {
      const img = new Image()
      img.onload = () => resolve(img)
      img.onerror = () => reject(new Error('not an image'))
      img.src = data
    }).catch(() => null)
    if (!probe) return
    let nw = probe.naturalWidth, nh = probe.naturalHeight
    // A photo straight off a camera is far more than a surface needs.
    const longest = Math.max(nw, nh)
    if (longest > 2600 || file.size > 6_000_000) {
      const k = Math.min(1, 2600 / longest)
      const canvas = document.createElement('canvas')
      canvas.width = Math.round(nw * k); canvas.height = Math.round(nh * k)
      canvas.getContext('2d')!.drawImage(probe, 0, 0, canvas.width, canvas.height)
      data = canvas.toDataURL(file.type === 'image/png' ? 'image/png' : 'image/jpeg', 0.9)
      nw = canvas.width; nh = canvas.height
    }
    const src = await saveAsset(data, file.name || 'image.png')
    const w = Math.min(480, nw), h = Math.round(w * nh / nw)
    const c = at ?? this.centre()
    const el = this.add({ id: newID(), type: 'image', x: Math.round(c.x - w / 2), y: Math.round(c.y - h / 2), w, h, src, name: file.name })
    this.sel = new Set([el.id])
    this.commit()
  }

  // MARK: pointer and keys

  private editable(target: EventTarget | null): boolean {
    const t = target as HTMLElement | null
    return !!t?.closest?.('input, textarea, [contenteditable="true"], .popup')
  }

  private hitID(target: EventTarget | null): string | null {
    const t = target as Element | null
    const hit = t?.closest?.('[data-id]') as HTMLElement | SVGElement | null
    return hit ? hit.getAttribute('data-id') : null
  }

  private listen() {
    const stage = this.stage
    stage.addEventListener('pointerdown', e => this.down(e))
    stage.addEventListener('pointermove', e => this.move(e))
    stage.addEventListener('pointerup', e => this.up(e))
    stage.addEventListener('pointercancel', e => this.up(e))
    stage.addEventListener('dblclick', e => this.double(e))
    stage.addEventListener('click', e => this.click(e))
    stage.addEventListener('wheel', e => this.wheel(e), { passive: false })
    stage.addEventListener('dragover', e => { if (e.dataTransfer?.types.includes('Files')) { e.preventDefault(); stage.classList.add('dropping') } })
    stage.addEventListener('dragleave', () => stage.classList.remove('dropping'))
    stage.addEventListener('drop', e => {
      stage.classList.remove('dropping')
      const files = [...(e.dataTransfer?.files ?? [])].filter(f => f.type.startsWith('image/'))
      if (!files.length) return
      e.preventDefault()
      const at = this.toWorld(e.clientX, e.clientY)
      files.forEach((f, i) => this.addImageFile(f, { x: at.x + i * 28, y: at.y + i * 28 }))
    })
    document.addEventListener('paste', e => {
      if (this.editing || this.editable(e.target)) return
      const files = [...(e.clipboardData?.files ?? [])].filter(f => f.type.startsWith('image/'))
      if (!files.length) return
      e.preventDefault()
      files.forEach(f => this.addImageFile(f))
    })
    document.addEventListener('keydown', e => this.key(e))
    document.addEventListener('keyup', e => { if (e.code === 'Space') { this.spaceDown = false; stage.classList.remove('panning') } })
    window.addEventListener('resize', () => this.drawUI())
    window.addEventListener('blur', () => this.flush())
  }

  private down(e: PointerEvent) {
    if (this.editable(e.target)) return
    const target = e.target as HTMLElement
    if (this.editing) {
      const node = this.nodes.get(this.editing.id)
      if (node?.contains(target)) return
      this.endEdit()
    }
    this.stage.setPointerCapture(e.pointerId)
    const p = this.toWorld(e.clientX, e.clientY)
    if (e.button === 1 || this.spaceDown || this.tool === 'hand') {
      this.gesture = { kind: 'pan', sx: e.clientX, sy: e.clientY, vx: this.view.x, vy: this.view.y }
      this.stage.classList.add('panning')
      return
    }
    const handle = target.closest?.('[data-handle]') as HTMLElement | null
    if (handle) {
      const id = [...this.sel][0], el = this.find(id)
      if (el) {
        this.gesture = { kind: 'resize', dir: handle.dataset.handle!, start: p, orig: norm(el), id, origEl: { ...el } }
        return
      }
    }
    const id = this.hitID(target)
    if (this.tool === 'connector') {
      const from = id && this.find(id)?.type !== 'connector' ? id : null
      if (from) this.gesture = { kind: 'connect', from, start: p }
      return
    }
    if (this.tool !== 'select') {
      this.gesture = { kind: 'create', tool: this.tool, start: p, el: null }
      return
    }
    if (id) {
      if (e.shiftKey) {
        if (this.sel.has(id)) this.sel.delete(id); else this.sel.add(id)
      } else if (!this.sel.has(id)) {
        this.sel = new Set([id])
      }
      this.drawUI()
      const origin = new Map<string, Point>()
      const take = (el: El) => origin.set(el.id, { x: el.x, y: el.y })
      for (const sid of this.sel) {
        const el = this.find(sid)
        if (!el || el.type === 'connector') continue
        take(el)
        if (el.type === 'frame') for (const child of this.inside(el)) if (!this.sel.has(child.id)) take(child)
      }
      this.gesture = { kind: 'move', start: p, origin, moved: false }
    } else {
      const base = e.shiftKey ? new Set(this.sel) : new Set<string>()
      this.sel = new Set(base)
      this.drawUI()
      this.gesture = { kind: 'marquee', start: p, base }
    }
  }

  private move(e: PointerEvent) {
    const g = this.gesture
    if (!g) return
    const p = this.toWorld(e.clientX, e.clientY)
    switch (g.kind) {
      case 'pan':
        this.touched = true
        this.view.x = g.vx + (e.clientX - g.sx)
        this.view.y = g.vy + (e.clientY - g.sy)
        this.applyView()
        break
      case 'move': {
        const dx = p.x - g.start.x, dy = p.y - g.start.y
        if (!g.moved && Math.hypot(dx, dy) * this.view.z < 3) return
        g.moved = true
        for (const [id, o] of g.origin) {
          const el = this.find(id)!
          el.x = Math.round(o.x + dx)
          el.y = Math.round(o.y + dy)
        }
        this.render()
        break
      }
      case 'resize':
        this.resize(g, p, e.shiftKey)
        break
      case 'marquee': {
        const rect = this.stage.getBoundingClientRect()
        const a = this.toScreen(g.start), b = this.toScreen(p)
        const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y)
        Object.assign(this.marqueeBox.style, { left: rect.left + x + 'px', top: rect.top + y + 'px', width: Math.abs(a.x - b.x) + 'px', height: Math.abs(a.y - b.y) + 'px' })
        this.marqueeBox.hidden = false
        const area = { x: Math.min(g.start.x, p.x), y: Math.min(g.start.y, p.y), w: Math.abs(p.x - g.start.x), h: Math.abs(p.y - g.start.y) }
        const next = new Set(g.base)
        for (const el of this.els) {
          if (el.type === 'connector') continue
          const n = norm(el)
          const hit = el.type === 'frame'
            ? n.x >= area.x && n.y >= area.y && n.x + n.w <= area.x + area.w && n.y + n.h <= area.y + area.h
            : n.x < area.x + area.w && n.x + n.w > area.x && n.y < area.y + area.h && n.y + n.h > area.y
          if (hit) next.add(el.id)
        }
        this.sel = next
        this.drawUI()
        break
      }
      case 'create': {
        const dx = p.x - g.start.x, dy = p.y - g.start.y
        if (!g.el) {
          if (Math.hypot(dx, dy) * this.view.z < 4) return
          g.el = this.add(this.makeEl(g.tool as ElType, g.start))
        }
        const el = g.el
        if (el.type === 'line' || el.type === 'arrow') {
          let w = dx, h = dy
          if (e.shiftKey) { if (Math.abs(w) > Math.abs(h) * 2) h = 0; else if (Math.abs(h) > Math.abs(w) * 2) w = 0; else { const m = Math.max(Math.abs(w), Math.abs(h)); w = Math.sign(w) * m; h = Math.sign(h) * m } }
          el.w = Math.round(w); el.h = Math.round(h)
        } else {
          let w = Math.abs(dx), h = Math.abs(dy)
          if (e.shiftKey && el.type !== 'text') w = h = Math.max(w, h)
          el.x = Math.round(dx < 0 ? g.start.x - w : g.start.x)
          el.y = Math.round(dy < 0 ? g.start.y - h : g.start.y)
          el.w = Math.round(w); el.h = Math.round(h)
          if (el.type === 'text') { el.w = Math.max(80, el.w); el.h = 32 }
        }
        this.render()
        break
      }
      case 'connect': {
        const from = this.find(g.from)
        if (!from) return
        const n = norm(from)
        const q = edgePoint(n, p)
        const a = this.toScreen(q), b = this.toScreen(p)
        this.preview.innerHTML = `<path d="M${a.x} ${a.y} L${b.x} ${b.y}"/>`
        const over = this.hitID(document.elementFromPoint(e.clientX, e.clientY))
        this.stage.querySelectorAll('.target').forEach(n => n.classList.remove('target'))
        if (over && over !== g.from) this.nodes.get(over)?.classList.add('target')
        break
      }
    }
  }

  private resize(g: Extract<Gesture, { kind: 'resize' }>, p: Point, shift: boolean) {
    const el = this.find(g.id)
    if (!el) return
    const dx = Math.round(p.x - g.start.x), dy = Math.round(p.y - g.start.y)
    if (g.dir === 'p1') { el.x = g.origEl.x + dx; el.y = g.origEl.y + dy; el.w = g.origEl.w - dx; el.h = g.origEl.h - dy; this.render(); return }
    if (g.dir === 'p2') {
      el.w = g.origEl.w + dx; el.h = g.origEl.h + dy
      if (shift) { if (Math.abs(el.w) > Math.abs(el.h) * 2) el.h = 0; else if (Math.abs(el.h) > Math.abs(el.w) * 2) el.w = 0 }
      this.render()
      return
    }
    const o = g.orig
    let { x, y, w, h } = o
    const minW = el.type === 'text' ? 80 : 12, minH = 12
    if (g.dir.includes('e')) w = Math.max(minW, o.w + dx)
    if (g.dir.includes('w')) { w = Math.max(minW, o.w - dx); x = o.x + o.w - w }
    if (g.dir.includes('s')) h = Math.max(minH, o.h + dy)
    if (g.dir.includes('n')) { h = Math.max(minH, o.h - dy); y = o.y + o.h - h }
    const corner = g.dir.length === 2
    if (corner && (el.type === 'image' || shift)) {
      h = Math.max(minH, Math.round(w * o.h / o.w))
      if (g.dir.includes('n')) y = o.y + o.h - h
    }
    el.x = x; el.y = y; el.w = w; el.h = el.type === 'text' ? el.h : h
    this.render()
  }

  private up(e: PointerEvent) {
    const g = this.gesture
    this.gesture = null
    if (!g) return
    this.stage.classList.remove('panning')
    if (this.stage.hasPointerCapture(e.pointerId)) this.stage.releasePointerCapture(e.pointerId)
    switch (g.kind) {
      case 'pan':
        this.scheduleSave()
        break
      case 'move':
        if (g.moved) this.commit()
        break
      case 'resize':
        this.commit()
        break
      case 'marquee':
        this.marqueeBox.hidden = true
        break
      case 'create': {
        let el = g.el
        if (!el) el = this.add(this.makeEl(g.tool as ElType, g.start))
        this.sel = new Set([el.id])
        this.setTool('select')
        this.sel = new Set([el.id])
        if (el.type === 'text') {
          this.render()
          this.startEdit(el.id)
        } else {
          this.commit()
        }
        break
      }
      case 'connect': {
        this.preview.innerHTML = ''
        this.stage.querySelectorAll('.target').forEach(n => n.classList.remove('target'))
        const over = this.hitID(document.elementFromPoint(e.clientX, e.clientY))
        if (over && over !== g.from && this.find(over) && this.find(over)!.type !== 'connector') {
          const c = this.add({ id: newID(), type: 'connector', x: 0, y: 0, w: 0, h: 0, from: g.from, to: over })
          this.setTool('select')
          this.sel = new Set([c.id])
          this.commit()
        }
        break
      }
    }
  }

  private click(e: MouseEvent) {
    const link = (e.target as HTMLElement).closest?.('.el.text a[href]') as HTMLAnchorElement | null
    if (link && !this.editing) {
      e.preventDefault()
      openLink(link.getAttribute('href') || '')
    }
  }

  private double(e: MouseEvent) {
    if (this.editable(e.target)) return
    const id = this.hitID(e.target)
    const el = id ? this.find(id) : undefined
    if (el?.type === 'text') { this.startEdit(el.id); return }
    if (el?.type === 'frame') {
      if ((e.target as HTMLElement).closest('.frame-label')) this.renameFrame(el.id)
      return
    }
    if (!el && this.tool === 'select') {
      const at = this.toWorld(e.clientX, e.clientY)
      const t = this.add(this.makeEl('text', { x: Math.round(at.x), y: Math.round(at.y) }))
      this.sel = new Set([t.id])
      this.render()
      this.startEdit(t.id)
    }
  }

  private wheel(e: WheelEvent) {
    e.preventDefault()
    const rect = this.stage.getBoundingClientRect()
    if (e.ctrlKey || e.metaKey) {
      const k = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.004))
      this.setZoom(this.view.z * k, { x: e.clientX - rect.left, y: e.clientY - rect.top })
    } else {
      this.touched = true
      this.view.x -= e.deltaX
      this.view.y -= e.deltaY
      this.applyView()
      this.scheduleSave()
    }
  }

  private key(e: KeyboardEvent) {
    const mod = e.metaKey || e.ctrlKey
    if (this.editing) {
      if (e.key === 'Escape' && !menuOpen()) { e.preventDefault(); this.endEdit() }
      return
    }
    if (this.editable(e.target)) return
    if (e.code === 'Space') {
      this.spaceDown = true
      this.stage.classList.add('panning')
      e.preventDefault()
      return
    }
    if (mod) {
      switch (e.key.toLowerCase()) {
        case 'z': e.preventDefault(); if (e.shiftKey) this.redo(); else this.undo(); return
        case 'y': e.preventDefault(); this.redo(); return
        case 'a': e.preventDefault(); this.selectAll(); return
        case 'd': e.preventDefault(); this.duplicate(); return
        case ']': e.preventDefault(); this.order(true); return
        case '[': e.preventDefault(); this.order(false); return
        case '=': case '+': e.preventDefault(); this.setZoom(this.view.z * 1.25); return
        case '-': e.preventDefault(); this.setZoom(this.view.z / 1.25); return
        case '0': e.preventDefault(); this.setZoom(1); return
      }
      return
    }
    if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); this.remove(); return }
    if (e.key === 'Escape') { this.sel.clear(); this.setTool('select'); this.drawUI(); return }
    if (e.key === 'Enter' && this.sel.size === 1) {
      const el = this.find([...this.sel][0])
      if (el?.type === 'text') { e.preventDefault(); this.startEdit(el.id) }
      return
    }
    const step = e.shiftKey ? 10 : 1
    if (e.key === 'ArrowLeft') { e.preventDefault(); this.nudge(-step, 0); return }
    if (e.key === 'ArrowRight') { e.preventDefault(); this.nudge(step, 0); return }
    if (e.key === 'ArrowUp') { e.preventDefault(); this.nudge(0, -step); return }
    if (e.key === 'ArrowDown') { e.preventDefault(); this.nudge(0, step); return }
    if (e.shiftKey && e.key === '1') { e.preventDefault(); this.fitAndSave(); return }
    const tools: Record<string, Tool> = { v: 'select', h: 'hand', f: 'frame', r: 'rect', o: 'ellipse', l: 'line', a: 'arrow', t: 'text', c: 'connector' }
    const tool = tools[e.key.toLowerCase()]
    if (tool) { e.preventDefault(); this.setTool(tool) }
  }
}
