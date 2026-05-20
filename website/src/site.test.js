import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const siteScript = readFileSync(new URL("./site.js", import.meta.url), "utf8");

function runSite(locationHref) {
  const codeNode = {
    textContent: "",
    cloneNode() {
      return {
        textContent: this.textContent,
        querySelectorAll() {
          return [];
        }
      };
    },
    querySelectorAll() {
      return [];
    }
  };

  const card = {
    querySelector(selector) {
      return selector === "code" ? codeNode : null;
    }
  };

  let clickHandler = null;
  let copiedText = "";
  const button = {
    attributes: new Map([["aria-label", "Copy install command"]]),
    classList: {
      add() {},
      remove() {}
    },
    addEventListener(event, handler) {
      if (event === "click") clickHandler = handler;
    },
    closest(selector) {
      return selector === ".command-code" ? card : null;
    },
    getAttribute(name) {
      return this.attributes.get(name) || null;
    },
    setAttribute(name, value) {
      this.attributes.set(name, value);
    }
  };

  const document = {
    hidden: false,
    addEventListener() {},
    querySelector() {
      return null;
    },
    querySelectorAll(selector) {
      if (selector === "[data-install-command]") return [codeNode];
      if (selector === "[data-copy-command]") return [button];
      return [];
    }
  };

  const window = {
    location: new URL(locationHref),
    matchMedia() {
      return { matches: false };
    },
    setTimeout(callback) {
      callback();
      return 1;
    },
    clearTimeout() {},
    addEventListener() {},
    requestAnimationFrame(callback) {
      callback();
      return 1;
    },
    innerHeight: 900,
    innerWidth: 1200,
    scrollY: 0
  };

  const navigator = {
    clipboard: {
      async writeText(value) {
        copiedText = value;
      }
    }
  };

  vm.runInNewContext(siteScript, { document, navigator, URL, window });

  return {
    command: codeNode.textContent,
    copy: async () => {
      expect(typeof clickHandler).toBe("function");
      await clickHandler();
      return copiedText;
    }
  };
}

test("install command strips URL userinfo and shell-quotes the installer URL", async () => {
  const page = runSite("https://$(touch$IFS.gitomi-pwned)@example.com/some/page?x=1#hero");

  expect(page.command).toBe("curl -fsSL 'https://example.com/install.sh' | sh");
  expect(page.command).not.toContain("$(");
  await expect(page.copy()).resolves.toBe(page.command);
});

test("install command keeps a safe current origin for local previews", () => {
  const page = runSite("http://localhost:4173/docs/index.html");

  expect(page.command).toBe("curl -fsSL 'http://localhost:4173/install.sh' | sh");
});

test("install command falls back to the canonical installer outside http origins", () => {
  const page = runSite("file:///tmp/gitomi/index.html");

  expect(page.command).toBe("curl -fsSL 'https://www.gitomi.com/install.sh' | sh");
});
