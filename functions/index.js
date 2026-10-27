const admin = require("firebase-admin");
const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const OpenAI = require("openai");

admin.initializeApp();

const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");
const OPENAI_MODEL = "gpt-5.4-mini";
const INTRODUCTORY_SCANS = 5;
const MAXIMUM_PAGE_COUNT = 6;

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
    const legacyImage = String(request.body?.imageBase64 || "");
    const requestedImages = Array.isArray(request.body?.imagesBase64) ? request.body.imagesBase64 : [];
    const imagesBase64 = (requestedImages.length ? requestedImages : [legacyImage]).map(String).filter(Boolean);
    const totalImageBytes = imagesBase64.reduce((total, image) => total + image.length, 0);
    if (!imagesBase64.length || imagesBase64.length > MAXIMUM_PAGE_COUNT || imagesBase64.some((image) => image.length > 8_000_000) || totalImageBytes > 28_000_000) {
      response.status(400).json({ error: "Add between one and six clear menu pages and try again." });
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
        response.status(429).json({ error: "You’ve used your five free scans. Upgrade to Vemuni Plus to continue." });
        return;
      }

      const openai = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
      const aiResponse = await openai.responses.create({
        model: OPENAI_MODEL,
        reasoning: { effort: "low" },
        input: [
          {
            role: "developer",
            content: [{ type: "input_text", text: systemPrompt(mode) }]
          },
          {
            role: "user",
            content: [
              {
                type: "input_text",
                text: mode === "menu"
                  ? `Read and explain this ${imagesBase64.length}-page menu. The selected pages may not be supplied in the restaurant's menu order.`
                  : "Analyze this restaurant bill."
              },
              ...imagesBase64.map((image) => ({
                type: "input_image",
                image_url: `data:image/jpeg;base64,${image}`,
                detail: "high"
              }))
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
      const usage = normalizedUsage(aiResponse.usage);
      result.aiUsage = {
        model: aiResponse.model || OPENAI_MODEL,
        ...usage
      };
      await recordSuccessfulScan(user.uid, allowance, {
        responseId: aiResponse.id,
        mode,
        pageCount: imagesBase64.length,
        model: aiResponse.model || OPENAI_MODEL,
        usage
      });
      response.status(200).json(result);
    } catch (error) {
      console.error("Vemuni scan failed", error);
      response.status(500).json({ error: "Vemuni could not read this image. Try a clearer, closer photo." });
    }
  }
);

function systemPrompt(mode) {
  const common = `You are Vemuni, a careful restaurant food, wine, drinks, and receipt reader. Analyze only visible evidence. Automatically detect the language and return clear American English. Preserve original item names. Never invent prices, totals, vintages, producers, regions, ingredients, allergens, dietary status, alcohol percentages, or fees. Use null or empty arrays when unknown. Allergens are possible indicators, not guarantees. Currency should be a three-letter ISO code when reasonably inferable, otherwise USD. The response must match the supplied JSON schema.`;

  if (mode === "receipt") {
    return `${common}\nThis is a restaurant bill. Extract visible line items and totals. Determine whether gratuity, service charge, or another fee is already included. Set possibleDuplicateTipRisk true whenever another tip could duplicate an included gratuity or service charge. Set tipBase to the subtotal before tax when visible. Set menuType to unknown and return no menu sections.`;
  }
  return `${common}\nThis is a restaurant menu that may contain food, wine, cocktails, beer, other drinks, or a mixture, across multiple pages that may be supplied in any order. Combine all pages into one menu and remove only exact duplicates caused by overlapping photos. Preserve the printed item order within each section, but arrange sections in a natural dining order: appetizers and starters, soups, salads, entrees and mains, sides, desserts, non-alcoholic drinks and mocktails, cocktails, beer, spirits, then wine. Classify the overall menuType and every section and item. Do not merge distinct items merely because their names are similar.

For food: explain the dish in plain English, including cooking style and important ingredients only when reasonably supported by visible text. Keep every explanation concise: one short sentence of no more than 18 words. Translate foreign descriptions naturally and explain unfamiliar culinary terms. If an item name is already English, set englishName exactly equal to originalName; do not paraphrase it, change capitalization, split compound words, or append a category such as salad, soup, appetizer, entree, or dessert. Put helpful clarification in explanation instead. Only make englishName different when an actual translation is needed.

Classify an item from what the item itself is, not from ingredients mentioned in its description. A food dish cooked with wine, beer, spirits, coffee, or tea remains food and must not be classified as a drink.

For every menu price: preserve whether it is fixed, market price, a choice of prices, or priced by a unit. Keep market price as "MP". Keep multiple visible prices and their labels when available. Format per-unit prices unambiguously, for example "36/oz" or "12 per person"—never collapse "$36/oz" into "36oz". Do not place a serving weight or bottle size in the price field. If a fixed price is not visible, use null rather than inferring one.

For wine: fill wineDetails and set drinkDetails to null. Printed facts such as producer, vintage, grape, region, country, and prices must come from visible text; use null when absent. You may provide a typical tasting profile, body, acidity, tannin, sweetness, general food pairings, and serving guidance when reasonably supported by the named grape, region, appellation, or recognized wine style. Set profileIsTypical true whenever any profile or pairing detail is inferred rather than printed. Do not imply that a typical characteristic was printed on the menu.

For cocktails, beer, and other drinks: fill drinkDetails and set wineDetails to null. Use visible ingredients. You may explain a widely recognized standard cocktail or drink style, but never invent a restaurant-specific ingredient or ABV. For food items, both detail objects must be null. Return receipt as null.`;
}

function resultSchema() {
  const nullableNumber = { anyOf: [{ type: "number" }, { type: "null" }] };
  const nullableString = { anyOf: [{ type: "string" }, { type: "null" }] };
  return {
    type: "object",
    additionalProperties: false,
    required: ["kind", "menuType", "detectedLanguage", "notice", "restaurantName", "currencyCode", "menuSections", "receipt", "warnings"],
    properties: {
      kind: { type: "string", enum: ["menu", "receipt"] },
      menuType: { type: "string", enum: ["food", "wine", "drinks", "mixed", "unknown"] },
      detectedLanguage: { type: "string" },
      notice: { type: "string" },
      restaurantName: nullableString,
      currencyCode: { type: "string" },
      menuSections: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["name", "sectionType", "items"],
          properties: {
            name: { type: "string" },
            sectionType: { type: "string", enum: ["food", "wine", "drink", "mixed", "unknown"] },
            items: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                required: ["originalName", "englishName", "explanation", "price", "itemType", "dietary", "allergens", "spiceLevel", "wineDetails", "drinkDetails"],
                properties: {
                  originalName: { type: "string" },
                  englishName: { type: "string" },
                  explanation: { type: "string" },
                  price: nullableString,
                  itemType: { type: "string", enum: ["food", "wine", "drink", "unknown"] },
                  dietary: { type: "array", items: { type: "string" } },
                  allergens: { type: "array", items: { type: "string" } },
                  spiceLevel: nullableString,
                  wineDetails: wineDetailsSchema(nullableString),
                  drinkDetails: drinkDetailsSchema(nullableString)
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

function wineDetailsSchema(nullableString) {
  return {
    anyOf: [
      { type: "null" },
      {
        type: "object",
        additionalProperties: false,
        required: ["producer", "grape", "region", "country", "vintage", "style", "glassPrice", "bottlePrice", "body", "acidity", "tannin", "sweetness", "alcohol", "flavors", "foodPairings", "servingSuggestion", "profileIsTypical"],
        properties: {
          producer: nullableString,
          grape: nullableString,
          region: nullableString,
          country: nullableString,
          vintage: nullableString,
          style: nullableString,
          glassPrice: nullableString,
          bottlePrice: nullableString,
          body: nullableString,
          acidity: nullableString,
          tannin: nullableString,
          sweetness: nullableString,
          alcohol: nullableString,
          flavors: { type: "array", items: { type: "string" } },
          foodPairings: { type: "array", items: { type: "string" } },
          servingSuggestion: nullableString,
          profileIsTypical: { type: "boolean" }
        }
      }
    ]
  };
}

function drinkDetailsSchema(nullableString) {
  return {
    anyOf: [
      { type: "null" },
      {
        type: "object",
        additionalProperties: false,
        required: ["drinkType", "baseSpirit", "ingredients", "flavorProfile", "abv"],
        properties: {
          drinkType: nullableString,
          baseSpirit: nullableString,
          ingredients: { type: "array", items: { type: "string" } },
          flavorProfile: { type: "array", items: { type: "string" } },
          abv: nullableString
        }
      }
    ]
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

  // Client access to vemuniUsers is denied by Firestore rules, so only an
  // administrator can grant this internal testing allowance.
  if (data.unlimitedTestScans === true) {
    return { allowed: true, type: "tester", introductoryUsed };
  }

  if (introductoryUsed < INTRODUCTORY_SCANS) {
    return { allowed: true, type: "introductory", introductoryUsed };
  }
  return { allowed: false, type: "exhausted", introductoryUsed };
}

function normalizedUsage(usage) {
  const tokenCount = (value) => {
    const number = Number(value || 0);
    return Number.isFinite(number) && number >= 0 ? Math.round(number) : 0;
  };
  return {
    inputTokens: tokenCount(usage?.input_tokens),
    cachedInputTokens: tokenCount(usage?.input_tokens_details?.cached_tokens),
    outputTokens: tokenCount(usage?.output_tokens),
    reasoningTokens: tokenCount(usage?.output_tokens_details?.reasoning_tokens),
    totalTokens: tokenCount(usage?.total_tokens)
  };
}

async function recordSuccessfulScan(uid, allowance, scanMetrics) {
  const ref = admin.firestore().collection("vemuniUsers").doc(uid);
  const usageRef = scanMetrics.responseId
    ? ref.collection("scanUsage").doc(String(scanMetrics.responseId))
    : ref.collection("scanUsage").doc();
  const usage = scanMetrics.usage;
  const update = {
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    totalSuccessfulScans: admin.firestore.FieldValue.increment(1),
    totalInputTokens: admin.firestore.FieldValue.increment(usage.inputTokens),
    totalCachedInputTokens: admin.firestore.FieldValue.increment(usage.cachedInputTokens),
    totalOutputTokens: admin.firestore.FieldValue.increment(usage.outputTokens),
    totalReasoningTokens: admin.firestore.FieldValue.increment(usage.reasoningTokens),
    totalTokens: admin.firestore.FieldValue.increment(usage.totalTokens),
    lastScanUsage: {
      mode: scanMetrics.mode,
      pageCount: scanMetrics.pageCount,
      model: scanMetrics.model,
      ...usage
    },
    lastScanUsageAt: admin.firestore.FieldValue.serverTimestamp()
  };
  if (allowance.type === "introductory") {
    update.introductoryUsed = admin.firestore.FieldValue.increment(1);
  }
  const batch = admin.firestore().batch();
  batch.set(ref, update, { merge: true });
  batch.set(usageRef, {
    responseId: scanMetrics.responseId || null,
    mode: scanMetrics.mode,
    pageCount: scanMetrics.pageCount,
    model: scanMetrics.model,
    ...usage,
    createdAt: admin.firestore.FieldValue.serverTimestamp()
  });
  await batch.commit();
}
