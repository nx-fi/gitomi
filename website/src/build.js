import { copyFile, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { renderSite } from "./content.js";

const here = dirname(fileURLToPath(import.meta.url));
const websiteRoot = join(here, "..");
const repoRoot = join(websiteRoot, "..");
const distDir = join(websiteRoot, "dist");

/** @type {Array<{ from: string, to: string }>} */
const copiedFiles = [
  { from: "cli/src/web/style.css", to: "assets/webui.css" },
  { from: "cli/src/web/logo.svg", to: "assets/logo.svg" },
  { from: "website/src/site.css", to: "assets/site.css" },
  { from: "website/src/site.js", to: "assets/site.js" },
  { from: "README.md", to: "docs/README.md" },
  { from: "cli/README.md", to: "docs/CLI.md" },
  { from: "spec/01_PRODUCT.md", to: "docs/01_PRODUCT.md" },
  { from: "spec/02_REFS.md", to: "docs/02_REFS.md" },
  { from: "spec/03_RBAC.md", to: "docs/03_RBAC.md" },
  { from: "spec/04_WORKFLOWS.md", to: "docs/04_WORKFLOWS.md" },
  { from: "spec/05_PROJECTS_WEBUI.md", to: "docs/05_PROJECTS_WEBUI.md" },
  { from: "spec/06_PULL_REQUEST_MERGE_SEMANTICS.md", to: "docs/06_PULL_REQUEST_MERGE_SEMANTICS.md" }
];

async function build() {
  await rm(distDir, { force: true, recursive: true });
  await Promise.all(
    copiedFiles.map(async (file) => {
      const destination = join(distDir, file.to);
      await mkdir(dirname(destination), { recursive: true });
      await copyFile(join(repoRoot, file.from), destination);
    })
  );

  await Bun.write(join(distDir, "index.html"), renderSite());
}

await build();
