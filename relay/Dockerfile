# 中継サーバーを自分の VPS などで動かすためのイメージ (Render を使う場合は不要)
FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY server.js ./
# root では動かさない
USER node
EXPOSE 8080
CMD ["node", "server.js"]
