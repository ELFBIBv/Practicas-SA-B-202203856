FROM node:20-alpine

WORKDIR /app

# Instalamos pnpm ya que el proyecto usa pnpm-lock.yaml
RUN npm install -g pnpm

COPY package.json pnpm-lock.yaml ./
RUN pnpm install

COPY . .

# Compilamos el proyecto TypeScript
RUN pnpm run build

EXPOSE 4000

CMD ["pnpm", "start"]
