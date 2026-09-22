// ===========================================================
// 프론트엔드 — 정적 파일 서버 + /api 리버스 프록시
//
// 왜 프록시가 여기 있는가:
//   화면의 스크립트는 API 를 상대경로(/api/chat)로 호출합니다. 그래야 프론트와
//   API 가 같은 오리진이 되어 CORS 가 필요 없어지기 때문입니다. 컨테이너 배포에서는
//   Caddy 가 그 역할을 했는데, Caddy 없이 호스트에서 직접 띄우는 구성에서는
//   /api 를 받아줄 주체가 사라져 브라우저 채팅이 동작하지 않았습니다.
//
//   프록시를 이 서버가 직접 맡으면 리버스 프록시 한 겹을 통째로 걷어낼 수 있습니다.
//   CSP 이관에서 옮겨야 할 구성 요소가 하나 줄어드는 게 핵심입니다.
//
// 외부 의존성을 쓰지 않은 이유:
//   http-proxy-middleware 같은 패키지를 붙일 수도 있지만, 여기서 필요한 건
//   JSON 요청 한 가지 경로뿐입니다(웹소켓도, 경로 재작성도 없음). Node 기본
//   http 모듈로 충분해서 의존성을 늘리지 않았습니다.
// ===========================================================

const express = require('express');
const path = require('path');
const http = require('http');

const app = express();

// -----------------------------------------------------------
// 백엔드 주소
//
//   Shell 형태  : http://127.0.0.1:8181/backend_spring  (tomcat7-maven-plugin)
//   컨테이너    : http://tomcat:8080                     (ROOT 로 배포되어 경로 없음)
//
// 두 형태의 포트와 컨텍스트 경로가 다르므로 환경변수로 받습니다.
// -----------------------------------------------------------
// ★ localhost 가 아니라 127.0.0.1 입니다. Node 17+ 는 DNS 결과를 받은 순서대로
// 쓰기 때문에 localhost 가 ::1(IPv6) 로 먼저 해석되는데, Tomcat 은 IPv4 에만
// 바인딩돼 있어 ECONNREFUSED 가 납니다. 로컬 테스트에서 실제로 재현됐습니다.
const BACKEND_URL = process.env.BACKEND_URL || 'http://127.0.0.1:8181/backend_spring';
const backend = new URL(BACKEND_URL);
const basePath = backend.pathname.replace(/\/+$/, ''); // '/backend_spring' 또는 ''

// LLM 생성이 길어질 수 있어 넉넉히 둡니다. 백엔드의 FastAPI 호출 타임아웃(180초)
// 보다 길게 잡아, 정상적인 느린 응답을 프록시가 먼저 끊지 않도록 합니다.
const PROXY_TIMEOUT_MS = 300000;

// -----------------------------------------------------------
// /api/* → 백엔드
//
// express.json() 같은 본문 파서를 두지 않았기 때문에 요청 스트림이 그대로
// 남아 있습니다. 그래서 req 를 프록시 요청에 바로 파이프할 수 있습니다.
// 파서를 추가하면 본문이 이미 소비되어 이 프록시가 멈추므로 주의하세요.
// -----------------------------------------------------------
app.use('/api', (req, res) => {
    const headers = Object.assign({}, req.headers, { host: backend.host });

    const proxyReq = http.request(
        {
            protocol: backend.protocol,
            hostname: backend.hostname,
            port: backend.port || (backend.protocol === 'https:' ? 443 : 80),
            method: req.method,
            path: basePath + req.originalUrl,
            headers,
        },
        (proxyRes) => {
            res.writeHead(proxyRes.statusCode, proxyRes.headers);
            proxyRes.pipe(res);
        }
    );

    proxyReq.setTimeout(PROXY_TIMEOUT_MS, () => {
        proxyReq.destroy(new Error(`백엔드 응답이 ${PROXY_TIMEOUT_MS / 1000}초를 넘었습니다`));
    });

    proxyReq.on('error', (err) => {
        console.error(`[proxy] ${req.method} ${req.originalUrl} -> ${BACKEND_URL} 실패:`, err.message);
        if (!res.headersSent) {
            res.status(502).json({ error: '백엔드에 연결할 수 없습니다.' });
        } else {
            res.end();
        }
    });

    req.pipe(proxyReq);
});

app.use(express.static(path.join(__dirname, 'public')));

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

const PORT = process.env.PORT || 3000;

app.listen(PORT, '0.0.0.0', () => {
    console.log(`프론트엔드 서버 실행 중: 포트 ${PORT}`);
    console.log(`  /api/* -> ${backend.origin}${basePath}`);
});
