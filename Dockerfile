# ---- Stage 1: build do frontend ----
FROM node:22-alpine AS frontend-build
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# ---- Stage 2: runtime (backend + estáticos do frontend) ----
FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY backend/ ./backend/
COPY --from=frontend-build /app/frontend/build ./frontend/build

RUN mkdir -p /app/uploads
VOLUME ["/app/uploads"]

EXPOSE 5000
CMD ["node", "backend/server.js"]
