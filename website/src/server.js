import { extname, join, normalize } from "node:path";

const port = Number.parseInt(process.env.PORT || "3036", 10);
const distDir = join(import.meta.dir, "..", "dist");

/** @type {Record<string, string>} */
const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".sh": "text/x-shellscript; charset=utf-8",
  ".svg": "image/svg+xml; charset=utf-8"
};

Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url);
    const requestedPath = url.pathname === "/" ? "/index.html" : url.pathname;
    const safePath = normalize(requestedPath).replace(/^(\.\.[/\\])+/, "");
    const filePath = join(distDir, safePath);
    const file = Bun.file(filePath);

    if (!(await file.exists())) {
      return new Response("Not found", { status: 404 });
    }

    return new Response(file, {
      headers: {
        "content-type": contentTypes[extname(filePath)] || "application/octet-stream"
      }
    });
  }
});

console.log(`Gitomi website serving http://localhost:${port}`);
