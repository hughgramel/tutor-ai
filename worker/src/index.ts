/**
 * InkTutor Proxy Worker
 *
 * Mints short-lived OpenAI Realtime client secrets so the iPad app never
 * ships with the raw OpenAI key. Session config (model, voice) lives here,
 * server-side, so the client binary contains no prompt/model choice.
 *
 * Ported from reference/clicky/worker/src/index.ts (try/catch + upstream
 * error passthrough), reduced to the one route we need.
 *
 * Routes:
 *   POST /realtime-token → OpenAI /v1/realtime/client_secrets
 */

import { INSTRUCTIONS } from "./instructions";

interface Env {
  OPENAI_API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/realtime-token") {
        return await mintRealtimeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(JSON.stringify({ error: String(error) }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
};

async function mintRealtimeToken(env: Env): Promise<Response> {
  const response = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      session: {
        type: "realtime",
        model: "gpt-realtime-2.1",
        instructions: INSTRUCTIONS,
        audio: {
          output: { voice: "cedar" },  // male; was marin
          // Student speech transcript (low-opacity "you: ..." line, see
          // VoiceBarView). Field shape verified against developers.openai.com/
          // api/reference (RealtimeSessionCreateResponse, session.audio.input.
          // transcription = { language, model, prompt }) on 2026-07-12 —
          // mirrors the existing session.audio.input.turn_detection/
          // noise_reduction pattern above it. Model choice: gpt-realtime-whisper
          // is the realtime guide's recommended pick ("Transcribe live audio
          // into streaming text → gpt-realtime-whisper", developers.openai.com/
          // api/docs/guides/realtime) — natively streaming, lower latency than
          // gpt-4o-mini-transcribe/whisper-1, and explicitly supported inside
          // type:"realtime" voice-agent sessions (not just standalone
          // transcription sessions).
          input: { transcription: { model: "gpt-realtime-whisper" } },
        },
      },
    }),
  });

  // Pass the upstream body through verbatim on failure — Task 1 Step 3 is the
  // demo-killer diagnostic, so we want OpenAI's actual error, not a swallowed 500.
  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/realtime-token] OpenAI error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: { "content-type": "application/json" },
  });
}
