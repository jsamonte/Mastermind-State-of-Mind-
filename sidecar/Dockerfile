# Presage sidecar, deployable so the hosted site can measure for any visitor.
#
# Base choice is load-bearing: the SmartSpectra native runtime is built on
# Ubuntu 22.04 and requires glibc >= 2.35. Debian 12 "bookworm" ships glibc 2.36.
# Alpine will NOT work — the runtime is glibc-only, musl is explicitly unsupported.
FROM node:22-bookworm-slim

WORKDIR /app

# Dependencies first so the layer caches across code changes.
# Note: `npm ci` pulls the native runtime for EVERY supported platform (a few
# hundred MB). Only the one matching the container is loaded at runtime; the
# others are dead weight in the image but there is no supported way to skip them.
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

COPY src ./src

# Containers have no loopback worth binding. This is the opt-in the server
# requires before it will listen on anything but 127.0.0.1.
ENV SIDECAR_HOST=0.0.0.0
ENV NODE_ENV=production

# Platforms inject PORT; the server prefers it over SIDECAR_PORT.
ENV PORT=8787
EXPOSE 8787

# Secrets are NEVER baked into the image. Supply at runtime:
#   PRESAGE_API_KEY          required for real measurement
#   GEMINI_API_KEY           required for the conversation
#   EXTRA_ORIGINS            comma-separated, e.g. https://your-app.web.app
#   AUTH0_DOMAIN             required to mint Firebase tokens
#   FIREBASE_SERVICE_ACCOUNT path to a mounted key file, if using persistence
#
# EXTRA_ORIGINS matters more here than anywhere else: it is the only thing
# stopping an arbitrary page from opening a socket and spending your Presage
# credits. Set it explicitly; do not rely on the default.

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/server.mjs"]
