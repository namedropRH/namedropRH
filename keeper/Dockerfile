# One-shot image. The timer on the host owns the schedule; this runs once and exits.
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY src ./src
# node:alpine ships an unprivileged `node` user. Without this line it would run as root,
# and a keeper holding a signing key has no business being root in its own container.
USER node
ENTRYPOINT ["node", "src/keeper.mjs"]
