/**
 * counsel.mjs - the conversation that happens after a reading.
 *
 * Presage says what state the body is in. This turns that into a short,
 * grounded conversation: tell the person what was measured, ask what decision
 * they are actually facing, and help them work out whether to act now or wait -
 * with concrete ways to settle and a realistic better time.
 *
 * Runs in the sidecar because the Gemini API key must never reach the browser.
 * Anything in a Flutter web bundle is public.
 */

/**
 * How long one model gets before the chain moves on. Short on purpose: someone
 * agitated is staring at a spinner, and a reply that arrives in 40s has already
 * failed even if it eventually lands.
 */
export const ATTEMPT_TIMEOUT_MS = Number(process.env.COUNSEL_TIMEOUT_MS ?? 14_000);

/**
 * How long to wait before starting the next model alongside the current one,
 * rather than after it. Lower means faster replies and more duplicate calls.
 */
export const HEDGE_DELAY_MS = Number(process.env.COUNSEL_HEDGE_MS ?? 5_000);

/** Tried in order. A 503 on demo day is not acceptable, so there are fallbacks. */
export const MODEL_CHAIN = [
  "gemini-flash-latest",
  "gemini-3-flash-preview",
  "gemini-3.1-flash-lite",
  "gemini-flash-lite-latest",
];

const ENDPOINT = (model) =>
  `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;

/**
 * The brief. Written out rather than minimised because every line here is a
 * decision about how this app treats someone who is upset.
 */
const SYSTEM_PROMPT = `You are Mastermind, a decision coach. Someone has just had their physiological
state measured through their webcam, and is about to make an important decision.

YOUR OPENING MESSAGE must do exactly two things, in this order:
1. Tell them whether they are in a GOOD, CONFLICTED, or BAD state of mind to
   make an important decision right now. Say which of those three it is, in
   those words, and back it with the actual numbers you were given.
2. Ask what decision they are trying to make.
Keep the opening to about three sentences. Do not add anything else to it.

AFTER THEY ANSWER, your job is to help them decide whether to act now or wait:
- Ask the question that makes the answer obvious to them, rather than lecturing.
- Offer something concrete to settle, and a realistic better time to revisit it.
- Tie your advice back to the state you measured when it is relevant.

STAY ON TOPIC. You only discuss this decision and decision-making itself: the
decision at hand, how their current state affects judgement, weighing options,
timing, reversibility, what they would advise a friend, how they will feel about
it tomorrow. If they raise something unrelated - trivia, code, general chat,
anything off-topic - say briefly that you are only here to help them think
through this decision, and ask a question that brings them back to it. Do not
answer the off-topic question, however easy it would be.

HOW TO WRITE:
- Short. Two or three sentences a turn, usually. Someone agitated will not read
  a paragraph, and a wall of text reads as a lecture.
- Plain, warm, direct. A steady friend, not a therapist and not a wellness brand.
- No emoji. No exclamation marks. No "I hear you". No "it sounds like you're
  feeling". Those phrases make people feel handled.
- Never open consecutive replies the same way.

WHAT YOU MUST NOT DO:
- Do not diagnose. These are wellness-grade signals from a camera, not a medical
  device. Never name a condition. Never say what someone "has".
- Do not overclaim the measurement. A high stress index means the measurement
  looked a certain way, not that you know their inner life. If the reading was
  inconclusive, say the measurement did not land and do not invent a state.
- Do not talk them into the impulsive thing. If they are arguing themselves into
  sending it, your job is to slow it down, not to agree. Being agreeable here
  does real harm.
- Equally, do not be a wall. If they are calm and the thing is reasonable,
  say so. Sometimes the right answer is "this seems fine, go do it". An app
  that always says wait gets ignored, and deserves to be.
- Do not moralise about what they want to do. No judgement about the purchase,
  the person, or the message.
- Do not promise the feeling will pass by a specific time. You do not know that.

IF SOMEONE IS IN REAL TROUBLE:
If they mention wanting to hurt themselves or anyone else, or sound like they are
in crisis, drop the decision framing entirely. Say clearly that you are a tool
for second-guessing purchases and text messages and not the right thing for this,
and that talking to a person would help - a crisis line, a doctor, or someone
they trust. In the US and Canada, 988 reaches the Suicide and Crisis Lifeline;
in the UK, Samaritans is 116 123. Be warm and brief. Do not keep coaching.`;

/**
 * Turns a composure reading into the factual block the model reasons from.
 * Deliberately plain text: the model is better at using this than JSON, and it
 * is readable in logs when the advice comes out wrong.
 */
export function describeReading(reading) {
  if (!reading || typeof reading !== "object") {
    return "No measurement is available for this person yet.";
  }

  const lines = [];
  const { composure, verdict } = reading;
  // Destructuring defaults only fire for `undefined`, so an explicit `null`
  // from a caller (or from JSON) would slip through and throw on property
  // access. Normalise both, and do not trust `reasons` to be an array.
  const signals = reading.signals ?? {};
  const reasons = Array.isArray(reading.reasons) ? reading.reasons : [];

  const provisional =
    typeof reading.provisional === "number" ? reading.provisional : null;

  if (composure == null || verdict === "inconclusive") {
    if (provisional != null) {
      // Refusing outright when real vitals DID arrive reads as the app being
      // broken rather than the light being poor. Give them the provisional
      // picture and the caveat together - silence is not the same as honesty.
      lines.push(
        `The measurement did not reach confident coverage, so there is no verdict ` +
          `and the app is releasing nothing on the strength of it. A PROVISIONAL ` +
          `score of ${provisional} out of 100 was computed from the signals that ` +
          `did survive (higher is calmer).`,
      );
      lines.push(
        "You MAY tell them what these numbers suggest and give them genuinely useful " +
          "feedback. You MUST also say clearly, in your own words, that this read was " +
          "low-confidence and what would fix it - usually more light on the face, " +
          "holding still, or sitting back so head and chest are both in frame. Do NOT " +
          "present the provisional number as a settled measurement, and do NOT treat " +
          "it as permission to act on the decision.",
      );
    } else {
      lines.push(
        "The measurement did NOT produce a confident reading. Do not describe their " +
          "state as if it were measured - say the read did not land, and ask them instead.",
      );
    }
  } else {
    lines.push(`Composure score: ${composure} out of 100 (higher is calmer).`);
    lines.push(
      `Verdict: ${verdict} - ${
        verdict === "green"
          ? "calm enough that the app would release the decision"
          : verdict === "amber"
            ? "borderline; the app suggests waiting a short while"
            : "agitated; the app is holding the decision back"
      }.`,
    );
  }

  const n = (v, digits = 0) => (typeof v === "number" ? v.toFixed(digits) : null);
  const pulse = n(signals.pulseRate);
  const breath = n(signals.breathingRate);
  const rmssd = n(signals.rmssd);
  const stress = n(signals.stressIndex);

  if (pulse) lines.push(`Pulse: ${pulse} bpm.`);
  if (breath) lines.push(`Breathing rate: ${breath} breaths per minute.`);
  if (rmssd) {
    lines.push(
      `Heart-rate variability (RMSSD): ${rmssd} ms. Lower suggests less ` +
        "parasympathetic 'rest' activity.",
    );
  }
  if (stress) {
    lines.push(
      `Baevsky stress index: ${stress}. Roughly 50-150 is typical at rest; ` +
        "higher suggests more strain.",
    );
  }
  if (reasons.length) {
    lines.push(`What the app flagged: ${reasons.join("; ")}.`);
  }

  return lines.join("\n");
}

/**
 * Builds the minter for conversation turns, or explains why it is unavailable.
 * Never throws on misconfiguration - the vault must still measure without it.
 *
 * @returns {{counsellor: {counsel: Function, models: string[]}|null, reason: string|null}}
 */
export function createCounsellor({ apiKey = process.env.GEMINI_API_KEY } = {}) {
  if (!apiKey) {
    return {
      counsellor: null,
      reason: "GEMINI_API_KEY is not set - see sidecar/.env.example",
    };
  }

  return {
    reason: null,
    counsellor: {
      models: MODEL_CHAIN,

      /**
       * One conversation turn.
       *
       * @param {object} args
       * @param {object} args.reading   the composure reading for context
       * @param {Array<{role:string, text:string}>} args.messages conversation so far
       * @param {AbortSignal} [args.signal]
       * @returns {Promise<{reply:string, model:string}>}
       */
      async counsel({ reading, messages = [], signal }) {
        const history = messages
          .filter((m) => m && typeof m.text === "string" && m.text.trim())
          // Gemini uses "model" where most APIs say "assistant".
          .map((m) => ({
            role: m.role === "assistant" || m.role === "model" ? "model" : "user",
            parts: [{ text: m.text.slice(0, 4000) }],
          }));

        // An opening turn has no user message yet: the app wants the assistant
        // to speak first, reporting the state and asking the question.
        const contents = history.length
          ? history
          : [
              {
                role: "user",
                parts: [
                  {
                    text:
                      "Open the conversation now: tell me whether I am in a good, " +
                      "conflicted, or bad state of mind to make an important decision, " +
                      "then ask what decision I am trying to make.",
                  },
                ],
              },
            ];

        const body = {
          systemInstruction: {
            parts: [{ text: `${SYSTEM_PROMPT}\n\nTHE MEASUREMENT:\n${describeReading(reading)}` }],
          },
          contents,
          generationConfig: {
            temperature: 0.8,
            maxOutputTokens: 8192,
            topP: 0.95,
          },
          // The conversation is about distress and impulse by design, so the
          // default filters are loosened one step to avoid refusing the app's
          // actual subject. Self-harm stays at the default threshold - that is
          // the one case where a refusal is better than advice.
          safetySettings: [
            { category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_ONLY_HIGH" },
            { category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_ONLY_HIGH" },
            { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_ONLY_HIGH" },
          ],
        };

        /** One model's attempt. Resolves with {reply, model} or throws. */
        const attempt = async (model, controller) => {
          // Bound each attempt, so one slow model cannot hold the whole reply.
          const signals = [controller.signal, AbortSignal.timeout(ATTEMPT_TIMEOUT_MS)];
          if (signal) signals.push(signal);

          const response = await fetch(`${ENDPOINT(model)}?key=${encodeURIComponent(apiKey)}`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body),
            signal: AbortSignal.any(signals),
          });

          const json = await response.json().catch(() => null);

          if (!response.ok) {
            const err = new Error(json?.error?.message ?? `Gemini returned ${response.status}`);
            err.status = response.status;
            throw err;
          }

          const candidate = json?.candidates?.[0];
          const reply = (candidate?.content?.parts ?? [])
            .map((p) => p?.text ?? "")
            .join("")
            .trim();

          if (!reply) {
            // A blocked or empty candidate is not a usable turn.
            throw new Error(
              candidate?.finishReason === "SAFETY"
                ? "The model declined to answer that."
                : `The model returned no text (finishReason: ${candidate?.finishReason ?? "unknown"}).`,
            );
          }
          return { reply, model };
        };

        // Hedged requests: start the next model before the previous has given
        // up, and take whichever answers first.
        //
        // Plain serial fallback stacked its timeouts — measured at 36s when the
        // first two models were under load — which is unusable for someone sat
        // watching a spinner. Hedging costs a few duplicate calls and bounds the
        // wait to roughly the fastest healthy model.
        return await new Promise((resolve, reject) => {
          const controllers = [];
          const timers = [];
          const errors = [];
          let launched = 0;
          let outstanding = 0;
          let settled = false;

          const finish = (fn, value) => {
            if (settled) return;
            settled = true;
            for (const t of timers) clearTimeout(t);
            // Abort the losers so their sockets close promptly. They reject
            // into the handler below, which is a no-op once settled.
            for (const c of controllers) c.abort();
            fn(value);
          };

          const launch = () => {
            if (settled || launched >= MODEL_CHAIN.length) return;
            const model = MODEL_CHAIN[launched++];
            const controller = new AbortController();
            controllers.push(controller);
            outstanding++;

            attempt(model, controller)
              .then((result) => finish(resolve, result))
              .catch((err) => {
                outstanding--;
                if (signal?.aborted) return finish(reject, err);
                errors.push(
                  err?.name === "TimeoutError" || err?.name === "AbortError"
                    ? new Error(`${model} did not answer within ${ATTEMPT_TIMEOUT_MS / 1000}s`)
                    : err,
                );
                if (launched < MODEL_CHAIN.length) launch();
                else if (outstanding === 0) {
                  finish(reject, errors.at(-1) ?? new Error("No Gemini model could be reached."));
                }
              });

            if (launched < MODEL_CHAIN.length) {
              timers.push(setTimeout(launch, HEDGE_DELAY_MS));
            }
          };

          launch();
        });
      },
    },
  };
}
