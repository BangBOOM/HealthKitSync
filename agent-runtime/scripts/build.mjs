import { build } from 'esbuild';
import { mkdir, writeFile, readFile, readdir } from 'node:fs/promises';

const output = new URL('../../HealthKitSync/Resources/Agent/', import.meta.url);
await mkdir(output, { recursive: true });
const result = await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: 'safari17',
  outfile: new URL('runtime.js', output).pathname,
  minify: true,
  legalComments: 'eof',
  metafile: true,
});
await mkdir('build', { recursive: true });
await writeFile('build/meta.json', JSON.stringify(result.metafile, null, 2));
const bundled = Object.values(result.metafile.outputs).flatMap((output) => Object.entries(output.inputs).filter(([, value]) => value.bytesInOutput > 0).map(([path]) => path));
const packages = [...new Set(bundled.map((path) => path.match(/^node_modules\/(@[^/]+\/[^/]+|[^/]+)/)?.[1]).filter(Boolean))].sort();
const notices = [];
for (const name of packages) {
  const directory = 'node_modules/' + name;
  const pkg = JSON.parse(await readFile(directory + '/package.json', 'utf8'));
  const license = (await readdir(directory)).find((file) => /^licen[sc]e(?:[.-].*)?$/i.test(file));
  const text = await readFile(license ? directory + '/' + license : name.startsWith('@earendil-works/') ? 'licenses/pi-LICENSE.txt' : (() => { throw new Error('Missing license for ' + name); })(), 'utf8');
  notices.push(`${name} ${pkg.version} (${pkg.license})\n${text}`);
}
await writeFile(new URL('licenses.txt', output), notices.join('\n\n----------------------------------------\n\n'));
console.log('Built browser runtime with Pi 0.85.1');
