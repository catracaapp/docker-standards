# =====================================================================
# Multi-stage Dockerfile: deps → app (código + deps) → dev / runner
# =====================================================================

FROM node:22-alpine AS base
WORKDIR /app

# ---- deps: instala node_modules -------------------------------------
FROM base AS deps
COPY package.json package-lock.json* ./
RUN npm install --omit=optional

# ---- app: snapshot autocontido (deps + código) ----------------------
# Dev e runner partem daqui pra não duplicar COPY.
FROM base AS dev
COPY --from=deps /app/node_modules ./node_modules
COPY package.json server.js ./
EXPOSE 3000
CMD ["npm", "run", "dev"]

# ---- runner: imagem final mínima, non-root --------------------------
FROM dev AS runner
ENV NODE_ENV=production
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 app && \
    chown -R app:nodejs /app
USER app
EXPOSE 3000
CMD ["node", "server.js"]
