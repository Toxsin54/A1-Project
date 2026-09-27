#!/usr/bin/env node
// Vapi asistanını system-prompt.md + tools.json dosyalarından oluşturur / günceller.
//
//   N8N_WEBHOOK_URL=https://n8n.ornek.com/webhook/vapi/reservations \
//   VAPI_WEBHOOK_SECRET=... VAPI_API_KEY=... node vapi/deploy.mjs
//
// --dry-run          : Vapi'ye göndermeden JSON'u ekrana basar
// VAPI_ASSISTANT_ID  : verilirse mevcut asistan güncellenir (PATCH), yoksa yeni oluşturulur
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const env = process.env;
const dryRun = process.argv.includes('--dry-run');

function required(name) {
  if (!env[name]) {
    if (dryRun) return `<${name}>`;
    console.error(`Eksik ortam değişkeni: ${name}`);
    process.exit(1);
  }
  return env[name];
}

const companyName = env.COMPANY_NAME || 'A1 Tur';
const webhookUrl = required('N8N_WEBHOOK_URL');
const webhookSecret = required('VAPI_WEBHOOK_SECRET');

const systemPrompt = readFileSync(join(here, 'system-prompt.md'), 'utf8')
  .replaceAll('__COMPANY_NAME__', companyName);

const tools = JSON.parse(readFileSync(join(here, 'tools.json'), 'utf8')).map((t) => ({
  type: 'function',
  async: false,
  function: { name: t.name, description: t.description, parameters: t.parameters },
  server: {
    url: webhookUrl,
    timeoutSeconds: 20,
    headers: { 'X-Vapi-Secret': webhookSecret },
  },
  messages: [
    { type: 'request-start', content: t.requestStart },
    {
      type: 'request-failed',
      content: 'Şu an sisteme ulaşamıyorum, kusura bakmayın. Bilgilerinizi alıp ekibimizin size dönmesini sağlayayım.',
    },
  ],
}));

const assistant = {
  name: env.VAPI_ASSISTANT_NAME || `${companyName} Rezervasyon Asistanı`,
  firstMessage: env.VAPI_FIRST_MESSAGE ||
    `Merhaba, ${companyName}'a hoş geldiniz, ben Ada. Size rezervasyon konusunda nasıl yardımcı olabilirim?`,
  model: {
    provider: env.VAPI_MODEL_PROVIDER || 'openai',
    model: env.VAPI_MODEL || 'gpt-4o',
    temperature: 0.3,
    messages: [{ role: 'system', content: systemPrompt }],
    tools,
  },
  transcriber: {
    provider: 'deepgram',
    model: env.VAPI_TRANSCRIBER_MODEL || 'nova-2',
    language: 'tr',
  },
  voice: {
    provider: '11labs',
    model: 'eleven_multilingual_v2',
    voiceId: required('ELEVENLABS_VOICE_ID'),
  },
  endCallMessage: 'Bizi tercih ettiğiniz için teşekkür ederiz, iyi günler dileriz.',
  maxDurationSeconds: 900,
};

if (dryRun) {
  console.log(JSON.stringify(assistant, null, 2));
  process.exit(0);
}

const id = env.VAPI_ASSISTANT_ID;
const res = await fetch(`https://api.vapi.ai/assistant${id ? `/${id}` : ''}`, {
  method: id ? 'PATCH' : 'POST',
  headers: {
    Authorization: `Bearer ${required('VAPI_API_KEY')}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify(assistant),
});
const body = await res.json().catch(() => ({}));
if (!res.ok) {
  console.error(`Vapi hatası (${res.status}):`, JSON.stringify(body, null, 2));
  process.exit(1);
}
console.log(`Asistan ${id ? 'güncellendi' : 'oluşturuldu'}: ${body.id}`);
console.log('Vapi panelinde telefon numaranızı bu asistana bağlayın.');
