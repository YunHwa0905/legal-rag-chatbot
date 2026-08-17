# ===========================================================
# 프론트엔드 — Express 정적 서버 (로그인 / 회원가입 / 채팅 3페이지)
# ===========================================================

FROM node:20-alpine

WORKDIR /app

# package-lock.json 이 있으므로 npm ci 로 재현 가능한 설치를 합니다.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js ./
COPY public ./public

ENV PORT=3000
EXPOSE 3000

CMD ["node", "server.js"]
