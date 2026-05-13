import { NextRequest, NextResponse } from "next/server";

export async function POST(req: NextRequest) {
  try {
    const { type, payload } = await req.json();
    const apiKey = process.env.OPENAI_API_KEY;

    if (!apiKey) {
      return NextResponse.json({ error: "No API key configured" }, { status: 500 });
    }

    // ─────────────────────────────────────────
    // TRANSCRIBE
    // ─────────────────────────────────────────
    if (type === "transcribe") {
      const audioBase64: string = payload.file;
      const buffer = Buffer.from(audioBase64, "base64");

      const formData = new FormData();
      formData.append("file", new Blob([buffer], { type: "audio/wav" }), "audio.wav");
      formData.append("model", "gpt-4o-transcribe");
      // язык не указываем → автоопределение

      const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}` },
        body: formData,
      });

      if (!response.ok) {
        const err = await response.json();
        return NextResponse.json({ error: err }, { status: response.status });
      }

      const data = await response.json();
      return NextResponse.json({
        result: data.text,
        language: data.language ?? null,
      });
    }

    // ─────────────────────────────────────────
    // TRANSLATE
    // ─────────────────────────────────────────
    if (type === "translate") {
      const text: string = payload.text;
      const targetLang: string = payload.targetLang ?? "auto";
      const detectedLang: string | null = payload.detectedLang ?? null;

      // Авто-определение направления перевода
      // Если язык известен и это русский/немецкий/польский → EN
      // Если английский → RU
      // Если неизвестен → EN (дефолт)
      let finalTarget: string;
      if (targetLang !== "auto") {
        finalTarget = targetLang;
      } else if (detectedLang === "en" || detectedLang === "en-US" || detectedLang === "en-GB") {
        finalTarget = "Russian";
      } else {
        // ru, de, pl, uk, или nil → всегда English
        finalTarget = "English";
      }

      const prompt = `Translate the following text to ${finalTarget}.\nReturn only the translation, no explanations.\n\nText:\n${text}`;

      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          messages: [
            { role: "system", content: "You are a professional translator. Return only the translation, nothing else." },
            { role: "user", content: prompt },
          ],
        }),
      });

      if (!response.ok) {
        const err = await response.json();
        return NextResponse.json({ error: err }, { status: response.status });
      }

      const data = await response.json();
      return NextResponse.json({
        result: data.choices[0]?.message?.content ?? "",
        targetLang: finalTarget,
      });
    }

    // ─────────────────────────────────────────
    // SUMMARY
    // ─────────────────────────────────────────
    if (type === "summary") {
      const text: string = payload.text;
      const mode: string = payload.mode ?? "standard";

      const prompts: Record<string, string> = {
        standard: `Summarize the following voice transcript concisely.

Rules:
- Write in the same language as the transcript
- Focus on WHAT was said, not HOW it was said
- No "speaker says" or "the speaker mentions"
- Be specific: include names, numbers, places if mentioned
- 3–5 bullet points
- Each bullet = one clear actionable or factual point

Text:
${text}`,

        legal: `Extract key legal facts from the following transcript.

Write in the same language as the transcript.
Format:
- [ФАКТ] key factual statement
- [ОБЯЗАТЕЛЬСТВО] any obligations mentioned  
- [РИСК] any risks or warnings
- [СРОК] any dates or deadlines

Text:
${text}`,

        erp: `Extract business actions from the following transcript.

Write in the same language as the transcript.
Format:
- [ЗАДАЧА] specific task + owner if mentioned
- [РЕШЕНИЕ] decisions made
- [ЧИСЛО] important numbers, amounts
- [РИСК] business risks

Text:
${text}`,

        action: `Extract all actionable items from the following transcript.

Write in the same language as the transcript.
Format:
- [ЗАДАЧА] specific task to do
- [РЕШЕНИЕ] decision that was made
- [РИСК] risk to be aware of
- [FOLLOWUP] things to follow up on

Be specific. No filler.

Text:
${text}`,
      };

      const prompt = prompts[mode] ?? prompts.standard;

      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          messages: [
            { role: "system", content: "You summarize voice transcripts into structured, specific bullet points. Write in the same language as the input." },
            { role: "user", content: prompt },
          ],
        }),
      });

      if (!response.ok) {
        const err = await response.json();
        return NextResponse.json({ error: err }, { status: response.status });
      }

      const data = await response.json();
      return NextResponse.json({
        result: data.choices[0]?.message?.content ?? "",
        mode,
      });
    }


    // ─────────────────────────────────────────
    // SPEAKERS
    // ─────────────────────────────────────────
    if (type === "speakers") {
      const text: string = payload.text;

      const prompt = `Analyse the following transcript and identify different speakers.
Label each speaker as "Speaker 1", "Speaker 2", etc. based on context clues (different topics, turn-taking, different perspectives).
Format each line as:
[Speaker N]: their text

Rules:
- Keep each speaker turn on a separate line
- Do not invent names unless explicitly mentioned in the text
- If only one speaker is detectable, use [Speaker 1] throughout
- Write the speaker's text in the same language as the transcript

Transcript:
${text}`;

      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          messages: [
            { role: "system", content: "You are a transcript analyst. Identify and label speakers in transcripts. Return only the labelled transcript, nothing else." },
            { role: "user", content: prompt },
          ],
        }),
      });

      if (!response.ok) {
        const err = await response.json();
        return NextResponse.json({ error: err }, { status: response.status });
      }

      const data = await response.json();
      return NextResponse.json({
        result: data.choices[0]?.message?.content ?? "",
      });
    }


    // ─────────────────────────────────────────
    // TIMELINE
    // ─────────────────────────────────────────
    if (type === "timeline") {
      const text: string = payload.text;
      const duration: number = payload.duration ?? 0;
      const speakers: string[] = payload.speakers ?? [];

      const speakerHint = speakers.length > 0
        ? `Known speakers in this recording: ${speakers.join(", ")}.\nWhen a speaker is identifiable, prefix the segment with [Speaker N]: text.`
        : "";

      const prompt = `You are analysing a voice recording transcript to build a chronological timeline.
The recording duration is approximately ${Math.round(duration)} seconds.
${speakerHint}

Rules:
- Divide the transcript into 4–10 meaningful segments
- Assign a realistic timestamp [MM:SS] to each segment based on the recording duration
- Each line must start with a timestamp in format [MM:SS]
- If a speaker is identifiable, add [Speaker N]: before the text
- Write segment text in the same language as the transcript
- Be concise: each segment should be 1–2 sentences
- No preamble, no explanations, only the timeline lines

Transcript:
${text}`;

      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          messages: [
            { role: "system", content: "You build chronological timelines from transcripts. Return only timestamp lines, nothing else." },
            { role: "user", content: prompt },
          ],
        }),
      });

      if (!response.ok) {
        const err = await response.json();
        return NextResponse.json({ error: err }, { status: response.status });
      }

      const data = await response.json();
      return NextResponse.json({
        result: data.choices[0]?.message?.content ?? "",
      });
    }

    return NextResponse.json({ error: "Invalid type" }, { status: 400 });
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : "Unknown error";
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}

export async function OPTIONS() {
  return new NextResponse(null, {
    status: 200,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    },
  });
}
