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
        // Drawing = silent function calls. Inline tags in the audio stream
        // got VOICED by the model ("circle eight") — a realtime voice model
        // speaks everything it generates, so pointing must ride the tool
        // channel instead. The client (RealtimeSession.tagForToolCall)
        // translates calls back into the internal tag grammar.
        tools: [
          {
            type: "function",
            name: "annotate",
            description:
              "Point at the student's ink. Draws a hand-styled circle/underline on one mark, or a curved arrow between two marks. Silent — pair it with your spoken words.",
            parameters: {
              type: "object",
              properties: {
                action: { type: "string", enum: ["circle", "underline", "arrow"] },
                mark: { type: "integer", description: "mark id (arrow: source)" },
                to: { type: "integer", description: "arrow target mark id (arrow only)" },
              },
              required: ["action", "mark"],
            },
          },
          {
            type: "function",
            name: "write_math",
            description:
              "Hand-write math on the page in the open space below the student's most recent work. LaTeX, one line per call.",
            parameters: {
              type: "object",
              properties: {
                latex: { type: "string" },
                below: { type: "integer", description: "optional mark id to write beneath; default = below everything" },
              },
              required: ["latex"],
            },
          },
          {
            type: "function",
            name: "draw_shape",
            description:
              "Draw a simple hand-styled diagram (polygon/line/curve) in open space. Points are normalized 0..1 [x,y] pairs.",
            parameters: {
              type: "object",
              properties: {
                kind: { type: "string", enum: ["polygon", "line", "curve"] },
                points: { type: "array", items: { type: "array", items: { type: "number" } } },
                label: { type: "string" },
              },
              required: ["kind", "points"],
            },
          },
          {
            type: "function",
            name: "pause",
            description:
              "End your turn and stay silent while the student works. Call last, nothing after it.",
            parameters: {
              type: "object",
              properties: { seconds: { type: "integer", description: "3-5 typical" } },
              required: ["seconds"],
            },
          },
        ],
        tool_choice: "auto",
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
