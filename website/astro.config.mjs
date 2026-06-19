// @ts-check
import { defineConfig } from "astro/config";

// Served on the custom domain https://devhq.app at the root, so `base` is "/".
const site = process.env.SITE_URL ?? "https://devhq.app";

export default defineConfig({
  site,
  base: "/",
  trailingSlash: "ignore",
  build: {
    format: "directory",
  },
  markdown: {
    shikiConfig: {
      theme: "github-dark-default",
    },
  },
});
