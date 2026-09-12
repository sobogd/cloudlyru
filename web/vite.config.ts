import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { cpSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * pdf.js подтягивает бинарные данные по URL: wasm (JBIG2 и JPEG2000 — это сканы),
 * cmaps (CJK-шрифты) и стандартные шрифты для PDF без встроенных шрифтов.
 * Копируем их из node_modules в public перед сборкой/девом: иначе пришлось бы
 * держать ~4 МБ бинарников в git, а без них часть PDF не отрисуется вовсе —
 * pdf.js падает с «Ensure that the `wasmUrl` API parameter is provided».
 */
const PDFJS_DATA = ['wasm', 'cmaps', 'standard_fonts'];
const PDFJS_DIST = fileURLToPath(new URL('./node_modules/pdfjs-dist', import.meta.url));
const PDFJS_PUBLIC = fileURLToPath(new URL('./public/pdfjs', import.meta.url));

function copyPdfjsData(): void {
  mkdirSync(PDFJS_PUBLIC, { recursive: true });
  for (const dir of PDFJS_DATA) {
    const from = `${PDFJS_DIST}/${dir}`;
    if (!existsSync(from)) continue;
    cpSync(from, `${PDFJS_PUBLIC}/${dir}`, { recursive: true });
  }
}
copyPdfjsData();

export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist' },
});
