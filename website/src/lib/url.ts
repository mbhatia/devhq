/**
 * Join the configured base path with a route so links work whether the site is
 * served from a sub-path (GitLab project pages) or the domain root.
 */
export function url(path = ""): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "");
  const clean = path.replace(/^\//, "");
  return clean ? `${base}/${clean}` : `${base}/`;
}
