const admin = require("firebase-admin");
const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const OpenAI = require("openai");

admin.initializeApp();

const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");
const OPENAI_MODEL = "gpt-5.4-mini";
const INTRODUCTORY_SCANS = 10;

exports.analyzeDiningPhoto = onRequest(
  {
    region: "us-central1",
    invoker: "public",
    secrets: [OPENAI_API_KEY],
    timeoutSeconds: 120,
    memory: "1GiB",
    cors: true
  },
  async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).json({ error: "Use POST." });
      return;
    }

    const mode = request.body?.mode === "receipt" ? "receipt" : "menu";
    const imageBase64 = String(request.body?.imageBase64 || "");
    if (!imageBase64 || imageBase64.length > 14_000_000) {
      response.status(400).json({ error: "A JPEG image under 10 MB is required." });
      return;
    }

    try {
      const user = await authenticatedUser(request);
      if (!user) {
        response.status(401).json({ error: "Sign in before scanning." });
        return;
      }
      const allowance = await scanAllowance(user.uid);
      if (!allowance.allowed) {
        response.status(429).json({ error: "Your free scan for today has been used. Try again tomorrow." });
        return;
      }

      const openai = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
      const aiResponse = await openai.responses.create({
        model: OPENAI_MODEL,
        input: [
          {
            role: "developer",
            content: [{ type: "input_text", text: systemPrompt(mode) }]
          },
          {
            role: "user",
            content: [
              { type: "input_text", text: mode === "menu" ? "Read and explain this menu." : "Analyze this restaurant bill." },
              { type: "input_image", image_url: `data:image/jpeg;base64,${imageBase64}`, detail: "high" }
            ]
          }
        ],
        text: {
          format: {
            type: "json_schema",
            name: "vemuni_scan",
            strict: true,
            schema: resultSchema()
          }
        }
      });

      const result = JSON.parse(aiResponse.output_text);
      await recordSuccessfulScan(user.uid, allowance);
      response.status(200).json(result);
    } catch (error) {
      console.error("Vemuni scan failed", error);
      response.status(500).json({ error: "Vemuni could not read this image. Try a clearer, closer photo." });
    }
  }
);

function systemPrompt(mode) {
  const common = `You are Vemuni, a careful restaurant menu and receipt reader. Analyze only visible evidence. Automatically detect the language and return clear American English. Preserve original dish names. Never invent prices, totals, ingredients, allergens, dietary status, or fees. Use null or empty arrays when unknown. Allergens are possible indicators, not guarantees. Currency should be a three-letter ISO code when reasonably inferable, otherwise USD. The response must match the supplied JSON schema.`;

  if (mode === "receipt") {
    return `${common}\nThis is a restaurant bill. Extract visible line items and totals. Determine whether gratuity, service charge, or another fee is already included. Set possibleDuplicateTipRisk true whenever another tip could duplicate an included gratuity or service charge. Set tipBase to the subtotal before tax when visible. Return no menu sections.`;
  }
  return `${common}\nThis is a restaurant menu. Organize dishes by visible section. Explain each dish in plain English, including cooking style and important ingredients only when reasonably supported by the name or description. Translate foreign descriptions naturally rather than word-for-word. For English menus, explain unfamiliar culinary terms. Return receipt as null.`;
}

function resultSchema() {
  const nullableNumber = { anyOf: [{ type: "number" }, { type: "null" }] };
  const nullableString = { anyOf: [{ type: "string" }, { type: "null" }] };
  return {
    type: "object",
    additionalProperties: false,
    required: ["kind", "detectedLanguage", "notice", "restaurantName", "currencyCode", "menuSections", "receipt", "warnings"],
    properties: {
      kind: { type: "string", enum: ["menu", "receipt"] },
      detectedLanguage: { type: "string" },
      notice: { type: "string" },
      restaurantName: nullableString,
      currencyCode: { type: "string" },
      menuSections: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["name", "items"],
          properties: {
            name: { type: "string" },
            items: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                required: ["originalName", "englishName", "explanation", "price", "dietary", "allergens", "spiceLevel"],
                properties: {
                  originalName: { type: "string" },
                  englishName: { type: "string" },
                  explanation: { type: "string" },
                  price: nullableString,
                  dietary: { type: "array", items: { type: "string" } },
                  allergens: { type: "array", items: { type: "string" } },
                  spiceLevel: nullableString
                }
              }
            }
          }
        }
      },
      receipt: {
        anyOf: [
          { type: "null" },
          {
            type: "object",
            additionalProperties: false,
            required: ["subtotal", "tax", "serviceCharge", "serviceChargeLabel", "statedTip", "total", "tipBase", "tipAlreadyIncluded", "possibleDuplicateTipRisk", "lineItems"],
            properties: {
              subtotal: nullableNumber,
              tax: nullableNumber,
              serviceCharge: nullableNumber,
              serviceChargeLabel: nullableString,
              statedTip: nullableNumber,
              total: nullableNumber,
              tipBase: nullableNumber,
              tipAlreadyIncluded: { type: "boolean" },
              possibleDuplicateTipRisk: { type: "boolean" },
              lineItems: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  required: ["name", "amount"],
                  properties: { name: { type: "string" }, amount: { type: "number" } }
                }
              }
            }
          }
        ]
      },
      warnings: { type: "array", items: { type: "string" } }
    }
  };
}

async function authenticatedUser(request) {
  const authorization = String(request.get("Authorization") || "");
  if (!authorization.startsWith("Bearer ")) return null;
  try {
    return await admin.auth().verifyIdToken(authorization.slice(7));
  } catch {
    return null;
  }
}

async function scanAllowance(uid) {
  const ref = admin.firestore().collection("vemuniUsers").doc(uid);
  const snapshot = await ref.get();
  const data = snapshot.data() || {};
  const introductoryUsed = Number(data.introductoryUsed || 0);
  const today = new Date().toISOString().slice(0, 10);
  if (introductoryUsed < INTRODUCTORY_SCANS) {
    return { allowed: true, type: "introductory", introductoryUsed, today };
  }
  return { allowed: data.lastDailyScanDay !== today, type: "daily", introductoryUsed, today };
}

async function recordSuccessfulScan(uid, allowance) {
  const ref = admin.firestore().collection("vemuniUsers").doc(uid);
  const update = {
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    totalSuccessfulScans: admin.firestore.FieldValue.increment(1)
  };
  if (allowance.type === "introductory") {
    update.introductoryUsed = admin.firestore.FieldValue.increment(1);
  } else {
    update.lastDailyScanDay = allowance.today;
  }
  await ref.set(update, { merge: true });
}
