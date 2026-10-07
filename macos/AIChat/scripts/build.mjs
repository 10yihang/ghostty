import { build } from "esbuild";
import { mkdir, copyFile, readFile, writeFile, readdir } from "node:fs/promises";

const outputDirectory = "dist/AIChat";
await mkdir(outputDirectory, { recursive: true });
const result = await build({
  entryPoints: ["src/chat.tsx"],
  outfile: `${outputDirectory}/chat.js`,
  bundle: true,
  minify: true,
  format: "iife",
  target: "safari16",
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "linked",
  metafile: true,
});
await copyFile("src/index.html", `${outputDirectory}/index.html`);

// Include the license notices for the packages actually present in the bundle.
const packages = new Set(Object.keys(result.metafile.inputs).flatMap((input) => {
  const match = input.match(/^node_modules\/((?:@[^/]+\/)?[^/]+)/);
  return match ? [match[1]] : [];
}));
const licenses = [];
for (const name of [...packages].sort()) {
  const directory = `node_modules/${name}`;
  const metadata = JSON.parse(await readFile(`${directory}/package.json`, "utf8"));
  const licenseFile = (await readdir(directory)).find((file) => /^licen[cs]e(?:\..*)?$/i.test(file));
  const license = licenseFile ? await readFile(`${directory}/${licenseFile}`, "utf8") : `License: ${metadata.license}`;
  licenses.push(`${name} ${metadata.version}\n${license.trim()}\n`);
}
await writeFile(`${outputDirectory}/THIRD_PARTY_LICENSES.txt`, licenses.join("\n--------------------\n\n"));
