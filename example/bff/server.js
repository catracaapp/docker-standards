// =====================================================================
// BFF (Express)
//
// O que esse BFF demonstra (além de servir como gateway):
//   1. Cookie HTTPOnly de sessão — visitor não enxerga via JS, browser
//      manda automaticamente. Auth/identidade ficam no servidor.
//   2. Composição de resposta — combina o "global" (vem do backend) com
//      o "mine" (mantido aqui em memória por sessão). Backend não sabe
//      que existe noção de "por usuário".
//   3. Internal token — adiciona X-Internal-Token nas chamadas pro
//      backend. Backend rejeita qualquer request sem esse header, então
//      ninguém de fora consegue pular o BFF e bater direto na API.
// =====================================================================

import express from 'express';
import cors from 'cors';
import cookieParser from 'cookie-parser';
import { randomBytes } from 'node:crypto';

const PORT = process.env.PORT || 3000;
const BACKEND_URL = process.env.BACKEND_URL || 'http://backend:8080';
const INTERNAL_TOKEN = process.env.INTERNAL_TOKEN || 'dev-shared-secret';

const app = express();
app.use(cors({ origin: true, credentials: true }));
app.use(cookieParser());
app.use(express.json());

// ---- Sessão em memória: sessionId -> { mine: N } ---------------------
// Em produção isso iria pro Redis. Aqui é só pra demonstrar o conceito.
const sessions = new Map();

function ensureSession(req, res) {
  let sid = req.cookies.sid;
  if (!sid || !sessions.has(sid)) {
    sid = randomBytes(16).toString('hex');
    sessions.set(sid, { mine: 0 });
    res.cookie('sid', sid, {
      httpOnly: true,           // JS do navegador NÃO acessa
      sameSite: 'lax',
      // secure: true,          // ligue em prod (HTTPS)
      maxAge: 24 * 60 * 60 * 1000, // 24h
    });
  }
  return { sid, state: sessions.get(sid) };
}

// ---- Helper: chama backend com o internal token ----------------------
async function callBackend(method) {
  const resp = await fetch(`${BACKEND_URL}/counter`, {
    method,
    headers: { 'X-Internal-Token': INTERNAL_TOKEN },
  });
  if (!resp.ok) {
    throw new Error(`backend ${method} /counter → ${resp.status}`);
  }
  return resp.json();
}

// ---- Rotas -----------------------------------------------------------
app.get('/api/counter', async (req, res, next) => {
  try {
    const { sid, state } = ensureSession(req, res);
    const backend = await callBackend('GET');
    res.json({
      service: 'bff',
      global: backend.global,
      mine: state.mine,
      session: sid.slice(0, 8) + '…',
    });
  } catch (err) {
    next(err);
  }
});

app.post('/api/counter', async (req, res, next) => {
  try {
    const { sid, state } = ensureSession(req, res);
    const backend = await callBackend('POST');
    state.mine += 1;
    res.json({
      service: 'bff',
      global: backend.global,
      mine: state.mine,
      session: sid.slice(0, 8) + '…',
    });
  } catch (err) {
    next(err);
  }
});

// Endpoint leve para polling: só o global, sem cookie, sem session.
// Frontend chama a cada 2s pra mostrar valor atualizado em tempo quase real.
app.get('/api/counter/global', async (_req, res, next) => {
  try {
    const backend = await callBackend('GET');
    res.json({
      global: backend.global,
      polledAt: new Date().toISOString(),
    });
  } catch (err) {
    next(err);
  }
});

app.get('/api/health', async (_req, res) => {
  try {
    const r = await fetch(`${BACKEND_URL}/health`);
    res.json({ service: 'bff', backend: await r.json() });
  } catch (err) {
    res.status(503).json({ service: 'bff', backend: 'unreachable', error: err.message });
  }
});

// ---- Error handler ---------------------------------------------------
app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: err.message });
});

app.listen(PORT, () => {
  console.log(`bff listening on :${PORT} (backend=${BACKEND_URL})`);
});
