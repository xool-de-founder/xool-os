// Bundles the canvas into ../../Resources/canvas (index.html, canvas.js, canvas.css).
// Run by web/canvas/build.sh; the result is checked in, so ./build.sh needs no Node.
import { build } from 'esbuild'
import { copyFileSync, mkdirSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const out = join(here, '..', '..', 'Resources', 'canvas')
rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })
await build({
  entryPoints: [join(here, 'src/main.ts')],
  outfile: join(out, 'canvas.js'),
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari16'],
  legalComments: 'none',
  logLevel: 'info',
  loader: { '.css': 'css' },
})
copyFileSync(join(here, 'index.html'), join(out, 'index.html'))
