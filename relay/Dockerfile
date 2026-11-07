# 中継サーバーを自分の VPS などで動かすためのイメージ (Render を使う場合は不要)
# タグの付け替えで中身が変わらないよう digest で固定 (node:22-alpine。更新は Dependabot)
FROM node:22-alpine@sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY server.js ./
# root では動かさない
USER node
EXPOSE 8080
CMD ["node", "server.js"]
