# syntax=docker/dockerfile:1.7

ARG OCTOPUS_REPO=https://github.com/octopusreview/octopus.git
ARG OCTOPUS_REF=master

FROM alpine/git:latest@sha256:d453f54c83320412aa89c391b076930bd8569bc1012285e8c68ce2d4435826a3 AS source
ARG OCTOPUS_REPO
ARG OCTOPUS_REF
WORKDIR /src
RUN git clone --depth 1 --branch "${OCTOPUS_REF}" "${OCTOPUS_REPO}" octopus || \
    (git clone --depth 1 "${OCTOPUS_REPO}" octopus && \
    cd octopus && \
    git fetch --depth 1 origin "${OCTOPUS_REF}" && \
    git checkout FETCH_HEAD)

FROM oven/bun:1-alpine@sha256:5acc90a93e91ff07bf72aa90a7c9f0fa189765aec90b47bdbf2152d2196383c0 AS base

FROM base AS deps
WORKDIR /app
COPY --from=source /src/octopus/package.json /src/octopus/bun.lock ./
COPY --from=source /src/octopus/apps/web/package.json ./apps/web/
COPY --from=source /src/octopus/packages/db/package.json ./packages/db/
COPY --from=source /src/octopus/packages/package-analyzer/package.json ./packages/package-analyzer/
COPY --from=source /src/octopus/tools/tsconfig/package.json ./tools/tsconfig/
COPY --from=source /src/octopus/tools/eslint-config/package.json ./tools/eslint-config/
RUN bun install --frozen-lockfile

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/web/node_modules ./apps/web/node_modules
COPY --from=deps /app/packages/db/node_modules ./packages/db/node_modules
COPY --from=source /src/octopus/tools ./tools
COPY --from=source /src/octopus/packages/db ./packages/db
COPY --from=source /src/octopus/packages/package-analyzer ./packages/package-analyzer
COPY --from=source /src/octopus/apps/web ./apps/web
COPY --from=source /src/octopus/package.json /src/octopus/bun.lock /src/octopus/turbo.json /src/octopus/CHANGELOG.md ./
ENV DATABASE_URL="postgresql://octopus:octopus@localhost:5432/dummy"
ENV BETTER_AUTH_SECRET="build-time-dummy-secret"
ENV BETTER_AUTH_URL="http://localhost:3000"
RUN touch .env
RUN cd packages/db && bun run db:generate
ARG NEXT_PUBLIC_BUILD_ID
ARG NEXT_PUBLIC_GITHUB_APP_SLUG
ARG NEXT_PUBLIC_PUBBY_KEY
ENV NEXT_PUBLIC_BUILD_ID=${NEXT_PUBLIC_BUILD_ID}
ENV NEXT_PUBLIC_GITHUB_APP_SLUG=${NEXT_PUBLIC_GITHUB_APP_SLUG}
ENV NEXT_PUBLIC_PUBBY_KEY=${NEXT_PUBLIC_PUBBY_KEY}
ENV NODE_OPTIONS="--max-old-space-size=4096"
RUN cd apps/web && bun run build

FROM node:22-alpine@sha256:968df39aedcea65eeb078fb336ed7191baf48f972b4479711397108be0966920 AS runner
WORKDIR /app
ENV NODE_ENV=production
RUN apk add --no-cache git libstdc++ && \
    addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs
COPY --from=base /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s /usr/local/bin/bun /usr/local/bin/bunx

COPY --from=builder --chown=nextjs:nodejs /app/apps/web/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/public ./apps/web/public
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder --chown=nextjs:nodejs /app/CHANGELOG.md ./CHANGELOG.md
COPY --from=builder --chown=nextjs:nodejs /app/package.json /app/bun.lock ./
COPY --from=builder --chown=nextjs:nodejs /app/packages/db ./packages/db
COPY --from=builder --chown=nextjs:nodejs /app/tools/tsconfig ./tools/tsconfig

USER nextjs
EXPOSE 3000
ENV HOSTNAME=0.0.0.0
ENV NODE_OPTIONS="--max-old-space-size=4096"
LABEL org.opencontainers.image.source="https://github.com/ne0ark/Octopus" \
      org.opencontainers.image.description="Self-hosted Octopus web app built from octopusreview/octopus"
CMD ["node", "apps/web/server.js"]
