// The block editor: TipTap with Notion's `/` menu. Every text element on the
// surface is one block document; it is shown as plain HTML and turned into an
// editor only while it is being written.

import { Editor, Extension, type Range } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import Suggestion from '@tiptap/suggestion'
import TaskList from '@tiptap/extension-task-list'
import TaskItem from '@tiptap/extension-task-item'
import { Table, TableRow, TableCell, TableHeader } from '@tiptap/extension-table'
import Image from '@tiptap/extension-image'
import Placeholder from '@tiptap/extension-placeholder'
import { generateHTML } from '@tiptap/html'
import { post, saveAsset, searchBrain, type BrainRef } from './bridge'

interface Command {
  title: string
  hint: string
  glyph: string
  words: string
  run: (editor: Editor, range: Range) => void
}

/** What `/` offers, in Notion's order. */
function commands(): Command[] {
  const clear = (editor: Editor, range: Range) => editor.chain().focus().deleteRange(range)
  return [
    { title: 'Text', hint: 'Plain paragraph', glyph: 'Aa', words: 'text paragraph plain',
      run: (e, r) => clear(e, r).setParagraph().run() },
    { title: 'Heading 1', hint: 'Large heading', glyph: 'H1', words: 'heading h1 title',
      run: (e, r) => clear(e, r).setNode('heading', { level: 1 }).run() },
    { title: 'Heading 2', hint: 'Medium heading', glyph: 'H2', words: 'heading h2',
      run: (e, r) => clear(e, r).setNode('heading', { level: 2 }).run() },
    { title: 'Heading 3', hint: 'Small heading', glyph: 'H3', words: 'heading h3',
      run: (e, r) => clear(e, r).setNode('heading', { level: 3 }).run() },
    { title: 'Bulleted list', hint: 'A simple list', glyph: '•', words: 'bullet list ul unordered',
      run: (e, r) => clear(e, r).toggleBulletList().run() },
    { title: 'Numbered list', hint: 'A list with numbers', glyph: '1.', words: 'numbered ordered list ol',
      run: (e, r) => clear(e, r).toggleOrderedList().run() },
    { title: 'To-do list', hint: 'Track tasks with checkboxes', glyph: '☐', words: 'todo task check list',
      run: (e, r) => clear(e, r).toggleTaskList().run() },
    { title: 'Quote', hint: 'Set a quotation apart', glyph: '“', words: 'quote blockquote citation',
      run: (e, r) => clear(e, r).toggleBlockquote().run() },
    { title: 'Code', hint: 'A block of code', glyph: '</>', words: 'code snippet pre',
      run: (e, r) => clear(e, r).toggleCodeBlock().run() },
    { title: 'Divider', hint: 'A line between blocks', glyph: '—', words: 'divider rule hr line separator',
      run: (e, r) => clear(e, r).setHorizontalRule().run() },
    { title: 'Image', hint: 'Pick a picture from this Mac', glyph: '▣', words: 'image picture photo',
      run: (e, r) => { clear(e, r).run(); pickImage(e) } },
    { title: 'Table', hint: 'Rows and columns', glyph: '⊞', words: 'table grid rows columns',
      run: (e, r) => clear(e, r).insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
    { title: 'Brain link', hint: 'Link an entry of your Brain', glyph: '◉', words: 'brain link reference entry note',
      run: (e, r) => { clear(e, r).run(); openBrainPicker(e) } },
    { title: 'Ask agent', hint: 'Ask an agent about this block', glyph: '✦', words: 'agent ask ai assistant',
      run: (e, r) => askAgent(e, r) },
  ]
}

function askAgent(editor: Editor, range: Range) {
  // The question is what was written before the slash, in this block;
  // the context is the whole element.
  const $from = editor.state.doc.resolve(range.from)
  const before = $from.parent.textBetween(0, $from.parentOffset, ' ').trim()
  const context = editor.getText({ blockSeparator: '\n' })
  editor.chain().focus().deleteRange(range).run()
  post({ type: 'ask', question: before, context: context.replace(/\/\s*$/, '').trim() })
}

// MARK: - popups

let popup: HTMLElement | null = null

function closePopup() {
  popup?.remove()
  popup = null
}

function place(box: HTMLElement, rect: DOMRect | null) {
  const margin = 8
  const r = rect ?? new DOMRect(window.innerWidth / 2, window.innerHeight / 2, 0, 0)
  const w = box.offsetWidth || 260
  const h = box.offsetHeight || 280
  let left = Math.min(Math.max(margin, r.left), window.innerWidth - w - margin)
  let top = r.bottom + 6
  if (top + h > window.innerHeight - margin) top = Math.max(margin, r.top - h - 6)
  box.style.left = left + 'px'
  box.style.top = top + 'px'
}

/** The `/` menu's list, drawn into one floating box that never takes focus from the editor. */
function slashRenderer() {
  let box: HTMLElement | null = null
  let items: Command[] = []
  let selected = 0
  let props: any

  const draw = () => {
    if (!box) return
    box.replaceChildren()
    if (!items.length) {
      const none = document.createElement('div')
      none.className = 'popup-empty'
      none.textContent = 'Nothing matches'
      box.append(none)
      return
    }
    items.forEach((item, i) => {
      const row = document.createElement('button')
      row.type = 'button'
      row.className = 'popup-row' + (i === selected ? ' on' : '')
      row.setAttribute('role', 'option')
      row.innerHTML = `<span class="glyph" aria-hidden="true"></span><span class="what"><span class="title"></span><span class="hint"></span></span>`
      ;(row.querySelector('.glyph') as HTMLElement).textContent = item.glyph
      ;(row.querySelector('.title') as HTMLElement).textContent = item.title
      ;(row.querySelector('.hint') as HTMLElement).textContent = item.hint
      row.addEventListener('mousedown', e => e.preventDefault())
      row.addEventListener('mousemove', () => {
        if (selected !== i) { selected = i; mark() }
      })
      row.addEventListener('click', () => props.command(item))
      box!.append(row)
    })
  }
  const mark = () => {
    box?.querySelectorAll('.popup-row').forEach((row, i) => row.classList.toggle('on', i === selected))
    box?.querySelectorAll('.popup-row')[selected]?.scrollIntoView({ block: 'nearest' })
  }

  return {
    onStart: (p: any) => {
      closePopup()
      props = p
      items = p.items
      selected = 0
      box = document.createElement('div')
      box.className = 'popup'
      box.setAttribute('role', 'listbox')
      box.setAttribute('aria-label', 'Blocks')
      box.addEventListener('mousedown', e => e.preventDefault())
      document.body.append(box)
      popup = box
      draw()
      place(box, p.clientRect?.() ?? null)
    },
    onUpdate: (p: any) => {
      props = p
      items = p.items
      selected = Math.min(selected, Math.max(0, items.length - 1))
      draw()
      if (box) place(box, p.clientRect?.() ?? null)
    },
    onKeyDown: ({ event }: { event: KeyboardEvent }) => {
      if (['ArrowDown', 'ArrowUp', 'Enter', 'Tab'].includes(event.key)) event.preventDefault()
      if (event.key === 'ArrowDown') { selected = (selected + 1) % Math.max(1, items.length); mark(); return true }
      if (event.key === 'ArrowUp') { selected = (selected - 1 + items.length) % Math.max(1, items.length); mark(); return true }
      if (event.key === 'Enter' || event.key === 'Tab') {
        if (items[selected]) props.command(items[selected])
        return true
      }
      if (event.key === 'Escape') { closePopup(); return false }
      return false
    },
    onExit: () => { if (popup === box) closePopup(); box = null },
  }
}

const SlashCommand = Extension.create({
  name: 'slashCommand',
  addProseMirrorPlugins() {
    return [
      Suggestion({
        editor: this.editor,
        char: '/',
        startOfLine: false,
        allowSpaces: false,
        items: ({ query }: { query: string }) => {
          const q = query.trim().toLowerCase()
          const all = commands()
          if (!q) return all
          return all.filter(c => (c.title + ' ' + c.words).toLowerCase().split(/\s+/).some(w => w.startsWith(q)) || c.title.toLowerCase().includes(q))
        },
        command: ({ editor, range, props }: any) => props.run(editor, range),
        render: slashRenderer,
      } as any),
    ]
  },
})

// MARK: - pickers

function pickImage(editor: Editor) {
  const input = document.createElement('input')
  input.type = 'file'
  input.accept = 'image/*'
  input.addEventListener('change', async () => {
    const file = input.files?.[0]
    if (!file) return
    const src = await saveAsset(await readAsDataURL(file), file.name)
    editor.chain().focus().setImage({ src, alt: file.name }).run()
  })
  input.click()
}

export function readAsDataURL(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })
}

/** A small search over the Brain; the choice goes in as a link the app opens. */
function openBrainPicker(editor: Editor) {
  closePopup()
  const box = document.createElement('div')
  box.className = 'popup picker'
  box.setAttribute('role', 'dialog')
  box.setAttribute('aria-label', 'Link a Brain entry')
  const input = document.createElement('input')
  input.type = 'text'
  input.placeholder = 'Search the Brain'
  input.setAttribute('aria-label', 'Search the Brain')
  const list = document.createElement('div')
  list.className = 'picker-list'
  box.append(input, list)
  document.body.append(box)
  popup = box

  const caret = (() => {
    const selection = window.getSelection()
    return selection && selection.rangeCount ? selection.getRangeAt(0).getBoundingClientRect() : null
  })()
  place(box, caret)

  let results: BrainRef[] = []
  let selected = 0
  let token = 0
  const draw = () => {
    list.replaceChildren()
    if (!results.length) {
      const none = document.createElement('div')
      none.className = 'popup-empty'
      none.textContent = input.value ? 'Nothing found in the Brain' : 'Type to search, or open the Brain and drop files in'
      list.append(none)
      return
    }
    results.forEach((r, i) => {
      const row = document.createElement('button')
      row.type = 'button'
      row.className = 'popup-row' + (i === selected ? ' on' : '')
      row.innerHTML = `<span class="what"><span class="title"></span><span class="hint"></span></span>`
      ;(row.querySelector('.title') as HTMLElement).textContent = r.title
      ;(row.querySelector('.hint') as HTMLElement).textContent = r.kind
      row.addEventListener('mousedown', e => e.preventDefault())
      row.addEventListener('click', () => choose(r))
      list.append(row)
    })
  }
  const choose = (r: BrainRef) => {
    closePopup()
    editor.chain().focus().insertContent({ type: 'text', text: r.title, marks: [{ type: 'link', attrs: { href: 'xool-brain://' + r.id } }] }).insertContent(' ').run()
  }
  const search = async () => {
    const mine = ++token
    const found = await searchBrain(input.value)
    if (mine !== token) return
    results = found
    selected = 0
    draw()
  }
  input.addEventListener('input', search)
  input.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown') { selected = Math.min(results.length - 1, selected + 1); draw(); e.preventDefault() }
    else if (e.key === 'ArrowUp') { selected = Math.max(0, selected - 1); draw(); e.preventDefault() }
    else if (e.key === 'Enter') { if (results[selected]) choose(results[selected]); e.preventDefault() }
    else if (e.key === 'Escape') { closePopup(); editor.commands.focus(); e.preventDefault(); e.stopPropagation() }
  })
  input.focus()
  search()
}

// MARK: - the editor and its static twin

export function extensions(placeholder = true) {
  return [
    StarterKit.configure({ link: { openOnClick: false, autolink: true, inclusive: false, HTMLAttributes: { rel: 'noopener' },
      // Brain entries are linked as xool-brain://id, which the app opens.
      isAllowedUri: (url: string, ctx: any) => url.startsWith('xool-brain://') || ctx.defaultValidate(url) } } as any),
    TaskList,
    TaskItem.configure({ nested: true }),
    Table.configure({ resizable: false }),
    TableRow,
    TableHeader,
    TableCell,
    Image.configure({ inline: false }),
    ...(placeholder ? [Placeholder.configure({
      placeholder: ({ node }: any) => (node.type.name === 'heading' ? 'Heading' : "Write, or type '/' for blocks"),
    }), SlashCommand] : []),
  ]
}

const staticExtensions = extensions(false)

/** A block document as HTML, for a text element at rest. */
export function renderDoc(doc: any): string {
  try {
    return generateHTML(doc, staticExtensions)
  } catch {
    return '<p></p>'
  }
}

export function isEmptyDoc(doc: any): boolean {
  const blocks = doc?.content ?? []
  if (blocks.length === 0) return true
  if (blocks.length > 1) return false
  const only = blocks[0]
  return only.type === 'paragraph' && !(only.content && only.content.length)
}

export function openEditor(host: HTMLElement, doc: any, onChange: () => void): Editor {
  const editor = new Editor({
    element: host,
    extensions: extensions(true),
    content: doc,
    editorProps: {
      attributes: { class: 'doc', 'aria-label': 'Text block', spellcheck: 'true' },
      handleClickOn: (_view, _pos, _node, _nodePos, event) => {
        const link = (event.target as HTMLElement | null)?.closest?.('a[href]') as HTMLAnchorElement | null
        if (link && (event.metaKey || event.ctrlKey)) {
          open(link.getAttribute('href') || '')
          return true
        }
        return false
      },
    },
    onUpdate: onChange,
  })
  // Now, not on the next tick: the first keys after a click belong to the block.
  editor.commands.focus('end')
  return editor
}

/** Opens a link the way a click on it should: Brain entries in the app, the rest in a tab. */
export function open(href: string) {
  if (!href) return
  if (href.startsWith('xool-brain://')) post({ type: 'openBrain', id: href.slice('xool-brain://'.length).replace(/\/$/, '') })
  else if (/^https?:/i.test(href)) post({ type: 'openURL', url: href })
}

export function closeMenus() {
  closePopup()
}

export function menuOpen(): boolean {
  return popup !== null
}
