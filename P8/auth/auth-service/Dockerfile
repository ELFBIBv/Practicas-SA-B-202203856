FROM node:20-alpine AS builder

WORKDIR /app
RUN npm install -g pnpm
COPY package.json pnpm-lock.yaml ./
RUN pnpm config set strict-dep-builds false && pnpm install
COPY . .
RUN pnpm run build

FROM node:20-alpine

# Trae los parches de seguridad ya publicados para esta misma versión de
# Alpine (no cambia de versión mayor, solo actualiza paquetes del SO).
RUN apk update && apk upgrade --no-cache

WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=builder --chown=appuser:appgroup /app/package.json /app/pnpm-lock.yaml ./
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /app/dist ./dist

USER 10001
EXPOSE 4000
CMD ["node", "dist/index.js"]
