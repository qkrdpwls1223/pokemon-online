# pmf-battle relay server. Zero npm dependencies.
FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ws.js ./
COPY tools ./tools
COPY test ./test
RUN mkdir -p /app/data && chown node:node /app/data
USER node
ENV NODE_ENV=production
EXPOSE 7777
CMD ["node", "server.js"]
