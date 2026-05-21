deploy-website:
	cd website && bun install --frozen-lockfile
	cd website && bun run deploy
