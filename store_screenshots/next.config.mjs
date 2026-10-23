/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: false,
  // Next 16.3+ otherwise writes AGENTS.md / CLAUDE.md into every scaffolded
  // project on first `dev`, leaving a dirty tree before anything is edited.
  agentRules: false,
  // Extra hosts the dev server answers (e.g. a `tailscale serve` name),
  // comma-separated: EDITOR_DEV_ORIGINS=my-mac.tailnet.ts.net bun dev
  allowedDevOrigins: (process.env.EDITOR_DEV_ORIGINS ?? "").split(",").filter(Boolean),
};

export default nextConfig;
