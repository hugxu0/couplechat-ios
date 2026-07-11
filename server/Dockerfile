FROM node:22-bookworm-slim

ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
COPY node_modules ./node_modules
COPY dist ./dist

RUN mkdir -p /app/uploads /app/.data && chown -R node:node /app
USER node

EXPOSE 8080
CMD ["node", "dist/server.js"]
