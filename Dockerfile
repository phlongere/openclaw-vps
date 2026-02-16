FROM node:22-bookworm AS builder

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

# Clone openclaw source
ARG OPENCLAW_REPO=https://github.com/openclaw/openclaw.git
ARG OPENCLAW_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_REF}" "${OPENCLAW_REPO}" .

# Install dependencies
RUN pnpm install --frozen-lockfile

# Build
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build

# Force pnpm for UI build (Bun may fail on ARM architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install
RUN pnpm ui:build

# --- Runtime stage ---
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    socat \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy built application from builder
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/ui/dist ./ui/dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/scripts ./scripts

ENV NODE_ENV=production

# Security: run as non-root (node user exists in node:22-bookworm-slim)
USER node

CMD ["node", "dist/index.js"]
