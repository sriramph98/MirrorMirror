import { cp, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = path.join(root, 'dist');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const file of ['index.html', 'styles.css', 'app.js', 'site-config.js', 'privacy', 'assets']) {
  await cp(path.join(root, file), path.join(output, file), { recursive: true });
}
console.log(`Built static website: ${output}`);
