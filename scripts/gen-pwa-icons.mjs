// Иконки PWA: web/public/icons/*.png. Источник — SVG ниже, поэтому пересобрать
// после правки логотипа просто: `node scripts/gen-pwa-icons.mjs` (нужен sharp из корня).
import { mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'web', 'public', 'icons');

// Габариты глифа (Material «cloud»): 24×24, вертикальный центр на y=12.
// scale подобран так, чтобы для maskable (Android обрезает по кругу ~80% площади)
// облако целиком осталось в безопасной зоне.
const cloud = (scale) => `
  <g transform="translate(${256 - 12 * scale} ${256 - 12 * scale}) scale(${scale})">
    <path fill="url(#g)" d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z"/>
  </g>`;

const svg = (scale) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="g" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0" stop-color="#2b6cff"/>
      <stop offset="1" stop-color="#8ec2ff"/>
    </linearGradient>
  </defs>
  <rect width="512" height="512" fill="#0f1115"/>
  ${cloud(scale)}
</svg>`);

const targets = [
  { file: 'icon-192.png', size: 192, scale: 17 },
  { file: 'icon-512.png', size: 512, scale: 17 },
  { file: 'icon-maskable-512.png', size: 512, scale: 13 }, // запас под обрезку Android
  { file: 'apple-touch-icon-180.png', size: 180, scale: 17 },
];

await mkdir(outDir, { recursive: true });
for (const { file, size, scale } of targets) {
  await sharp(svg(scale), { density: 96 }).resize(size, size).png().toFile(join(outDir, file));
  console.log(`${file} — ${size}×${size}`);
}
