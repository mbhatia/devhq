/** Ordered docs navigation. Add a page here and create the matching markdown. */
export interface DocLink {
  title: string;
  slug: string;
  summary: string;
}

export const docsNav: DocLink[] = [
  {
    title: "Getting started",
    slug: "getting-started",
    summary: "Install DevHQ and open your first worktree.",
  },
  {
    title: "Concepts",
    slug: "concepts",
    summary: "The model: repositories, worktrees, agents, review.",
  },
  {
    title: "Worktrees",
    slug: "worktrees",
    summary: "Track parallel work. Local and remote.",
  },
  {
    title: "Agents",
    slug: "agents",
    summary: "Launch, supervise, and resume coding agents.",
  },
  {
    title: "Review",
    slug: "review",
    summary: "Diffs, inline comments, and the agent reply loop.",
  },
  {
    title: "Commands",
    slug: "commands",
    summary: "Every command and the review CLI.",
  },
];

export const GITHUB_URL = "https://github.com/mbhatia/devhq";
export const INSTALL_CMD =
  "curl -fsSL https://raw.githubusercontent.com/mbhatia/devhq/main/install.sh | sh";
