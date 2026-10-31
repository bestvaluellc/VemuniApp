const admin = require("firebase-admin");
const crypto = require("crypto");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const OpenAI = require("openai");

admin.initializeApp();

const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");
const OPENAI_MODEL = "gpt-5.4-mini";
const FAST_OPENAI_MODEL = "gpt-4.1-mini";
const INTRODUCTORY_SCANS = 5;
const MAXIMUM_PAGE_COUNT = 6;
const SHARED_MENU_BASE_URL = "https://vemuni.bestvaluellc.com/menu/";

exports.getVemuniPlusStatus = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 15,
    memory: "256MiB",
    maxInstances: 5,
    invoker: "public"
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in to Vemuni before checking Plus access.");
    }
    const snapshot = await admin.firestore()
      .collection("proAccessOverrides")
      .doc(request.auth.uid)
      .get();
    const overrideEnabled = snapshot.data()?.enabled === true;
    console.log("Vemuni Plus override check", {
      uid: request.auth.uid,
      overrideEnabled
    });
    return { overrideEnabled };
  }
);

exports.createSharedMenu = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 15,
    memory: "256MiB",
    maxInstances: 20,
    invoker: "public"
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in before sharing a menu.");
    }
    const menu = sanitizedSharedMenu(request.data?.menu);
    const id = crypto.randomBytes(9).toString("base64url");
    await admin.firestore().collection("sharedMenus").doc(id).set({
      ownerUid: request.auth.uid,
      menu,
      createdAt: admin.firestore.FieldValue.serverTimestamp()
    });
    return {
      id,
      url: `${SHARED_MENU_BASE_URL}?id=${encodeURIComponent(id)}`
    };
  }
);

exports.getSharedMenu = onRequest(
  {
    region: "us-central1",
    timeoutSeconds: 15,
    memory: "256MiB",
    maxInstances: 50,
    invoker: "public",
    cors: true
  },
  async (request, response) => {
    if (request.method !== "GET") {
      response.status(405).json({ error: "Use GET." });
      return;
    }
    const id = String(request.query?.id || "");
    if (!/^[A-Za-z0-9_-]{12}$/.test(id)) {
      response.status(400).json({ error: "This menu link is invalid." });
      return;
    }
    const snapshot = await admin.firestore().collection("sharedMenus").doc(id).get();
    const data = snapshot.data();
    if (!snapshot.exists || !data?.menu) {
      response.status(404).json({ error: "This shared menu was not found." });
      return;
    }
    response.set("Cache-Control", "private, max-age=60");
    response.status(200).json({
      menu: data.menu
    });
  }
);

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
    const requestStartedAt = Date.now();
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

      const aiStartedAt = Date.now();
      const openai = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
      const aiResponses = [await analyzeWithOpenAI(
        openai,
        mode,
        imagesBase64,
        mode === "menu"
          ? `Read and explain this ${imagesBase64.length}-page menu. The selected pages may not be supplied in the restaurant's menu order.`
          : "Analyze this restaurant bill."
      )];
      const aiCompletedAt = Date.now();

      const pageResults = aiResponses.map((aiResponse) => JSON.parse(aiResponse.output_text));
      const result = pageResults[0];
      const allAiResponses = aiResponses;
      const usage = sumUsage(allAiResponses.map((aiResponse) => normalizedUsage(aiResponse.usage)));
      const primaryResponse = aiResponses[0];
      result.aiUsage = {
        model: primaryResponse.model || OPENAI_MODEL,
        ...usage
      };
      const timing = {
        imagePayloadCharacters: totalImageBytes,
        serviceTier: primaryResponse.service_tier || "unknown",
        processingMode: "combined-full-wine-detail",
        aiCallCount: allAiResponses.length,
        wineProfileCount: result.menuSections
          .flatMap((section) => section.items)
          .filter((item) => item.wineDetails !== null).length,
        preAiMs: aiStartedAt - requestStartedAt,
        aiMs: aiCompletedAt - aiStartedAt
      };
      await recordSuccessfulScan(user.uid, allowance, {
        responseId: primaryResponse.id,
        mode,
        pageCount: imagesBase64.length,
        model: primaryResponse.model || OPENAI_MODEL,
        usage,
        timing
      });
      const requestCompletedAt = Date.now();
      console.log(JSON.stringify({
        event: "vemuni_scan_timing",
        mode,
        pageCount: imagesBase64.length,
        model: primaryResponse.model || OPENAI_MODEL,
        ...timing,
        postAiMs: requestCompletedAt - aiCompletedAt,
        totalServerMs: requestCompletedAt - requestStartedAt,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        reasoningTokens: usage.reasoningTokens
      }));
      response.status(200).json(result);
    } catch (error) {
      console.error("Vemuni scan failed", error);
      response.status(500).json({ error: "Vemuni could not read this image. Try a clearer, closer photo." });
    }
  }
);

exports.analyzeDiningPhotoFast = onRequest(
  {
    region: "us-central1",
    invoker: "public",
    secrets: [OPENAI_API_KEY],
    timeoutSeconds: 120,
    memory: "1GiB",
    cors: true
  },
  async (request, response) => {
    const requestStartedAt = Date.now();
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

      const aiStartedAt = Date.now();
      const openai = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
      const parallelPages = mode === "menu" && imagesBase64.length > 1;
      const aiResponses = parallelPages
        ? await Promise.all(imagesBase64.map((image, index) => analyzeFastWithOpenAI(
          openai,
          mode,
          [image],
          `Read and explain menu page ${index + 1}.`
        )))
        : [await analyzeFastWithOpenAI(
          openai,
          mode,
          imagesBase64,
          mode === "menu" ? "Read and explain this menu." : "Analyze this restaurant bill."
        )];
      const aiCompletedAt = Date.now();

      const pageResults = aiResponses.map((aiResponse) => expandCompactResult(JSON.parse(aiResponse.output_text)));
      const result = parallelPages ? mergeMenuResults(pageResults) : pageResults[0];
      const usage = sumUsage(aiResponses.map((aiResponse) => normalizedUsage(aiResponse.usage)));
      const primaryResponse = aiResponses[0];
      result.aiUsage = {
        model: primaryResponse.model || FAST_OPENAI_MODEL,
        ...usage
      };
      const timing = {
        imagePayloadCharacters: totalImageBytes,
        serviceTier: primaryResponse.service_tier || "unknown",
        processingMode: parallelPages ? "debug-fast-parallel" : "debug-fast-single",
        aiCallCount: aiResponses.length,
        wineProfileCount: result.menuSections
          .flatMap((section) => section.items)
          .filter((item) => item.wineDetails !== null).length,
        preAiMs: aiStartedAt - requestStartedAt,
        aiMs: aiCompletedAt - aiStartedAt
      };
      await recordSuccessfulScan(user.uid, allowance, {
        responseId: parallelPages ? `${primaryResponse.id}_fast_p${aiResponses.length}` : `${primaryResponse.id}_fast`,
        mode,
        pageCount: imagesBase64.length,
        model: primaryResponse.model || FAST_OPENAI_MODEL,
        usage,
        timing
      });
      const requestCompletedAt = Date.now();
      console.log(JSON.stringify({
        event: "vemuni_scan_timing",
        strategy: "debug-fast",
        mode,
        pageCount: imagesBase64.length,
        model: primaryResponse.model || FAST_OPENAI_MODEL,
        ...timing,
        postAiMs: requestCompletedAt - aiCompletedAt,
        totalServerMs: requestCompletedAt - requestStartedAt,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        reasoningTokens: usage.reasoningTokens
      }));
      response.status(200).json(result);
    } catch (error) {
      console.error("Vemuni fast scan failed", error);
      response.status(500).json({ error: "Vemuni could not read this image. Try a clearer, closer photo." });
    }
  }
);

async function analyzeWithOpenAI(openai, mode, imagesBase64, instruction) {
  return openai.responses.create({
    model: OPENAI_MODEL,
    service_tier: "fast",
    reasoning: { effort: "low" },
    input: [
      {
        role: "developer",
        content: [{ type: "input_text", text: systemPrompt(mode) }]
      },
      {
        role: "user",
        content: [
          { type: "input_text", text: instruction },
          ...imagesBase64.map((image) => ({
            type: "input_image",
            image_url: `data:image/jpeg;base64,${image}`,
            detail: "low"
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
}

async function analyzeFastWithOpenAI(openai, mode, imagesBase64, instruction) {
  return openai.responses.create({
    model: FAST_OPENAI_MODEL,
    service_tier: "default",
    input: [
      {
        role: "developer",
        content: [{ type: "input_text", text: fastSystemPrompt(mode) }]
      },
      {
        role: "user",
        content: [
          { type: "input_text", text: instruction },
          ...imagesBase64.map((image) => ({
            type: "input_image",
            image_url: `data:image/jpeg;base64,${image}`,
            detail: "low"
          }))
        ]
      }
    ],
    text: {
      format: {
        type: "json_schema",
        name: "vemuni_fast_scan",
        strict: true,
        schema: compactResultSchema()
      }
    }
  });
}

function fastSystemPrompt(mode) {
  return `${systemPrompt(mode)}\nFor this debug fast response, use compact keys: top level k=kind, mt=menuType, l=detectedLanguage, n=notice, r=restaurantName, c=currencyCode, s=menuSections, rec=receipt, w=warnings; section n=name, t=sectionType, i=items; item o=originalName, e=englishName, x=explanation, p=price, t=itemType, d=dietary, a=allergens, sp=spiceLevel, wi=wineDetails, dr=drinkDetails; wine p=producer, g=grape, r=region, c=country, v=vintage, s=style, gp=glassPrice, bp=bottlePrice, b=body, ac=acidity, ta=tannin, sw=sweetness, al=alcohol, f=flavors, fp=foodPairings, ss=servingSuggestion, typ=profileIsTypical; drink t=drinkType, b=baseSpirit, i=ingredients, f=flavorProfile, a=abv; receipt sub=subtotal, tax=tax, sc=serviceCharge, scl=serviceChargeLabel, tip=statedTip, tot=total, tb=tipBase, ti=tipAlreadyIncluded, dup=possibleDuplicateTipRisk, li=lineItems; receipt line item n=name, a=amount.`;
}

async function analyzeWineProfiles(openai, imageBase64) {
  return openai.responses.create({
    model: OPENAI_MODEL,
    service_tier: "default",
    input: [
      {
        role: "developer",
        content: [{
          type: "input_text",
          text: "Read only wines visible on this menu page. If there are no wines, return an empty array. Preserve each printed wine name. Never invent printed producer, grape, region, country, vintage, style, or prices; use null when absent. For every visible wine, provide a concise typical body, acidity, tannin, sweetness, flavors, food pairings, and serving suggestion when supported by the visible name, grape, region, appellation, or recognized style. Mark inferred profiles as typical. Compact keys: w=wines, n=originalName, d=wineDetails; within d, p=producer, g=grape, r=region, c=country, v=vintage, s=style, gp=glassPrice, bp=bottlePrice, b=body, ac=acidity, ta=tannin, sw=sweetness, al=alcohol, f=flavors, fp=foodPairings, ss=servingSuggestion, typ=profileIsTypical. Match the JSON schema."
        }]
      },
      {
        role: "user",
        content: [{
          type: "input_image",
          image_url: `data:image/jpeg;base64,${imageBase64}`,
          detail: "low"
        }]
      }
    ],
    text: {
      format: {
        type: "json_schema",
        name: "vemuni_wine_profiles",
        strict: true,
        schema: wineProfileResultSchema()
      }
    }
  });
}

function systemPrompt(mode) {
  const common = `You are Vemuni, a careful restaurant food, wine, drinks, and receipt reader. Analyze only visible evidence. Automatically detect the language and return clear American English. Preserve original item names. Never invent prices, totals, vintages, producers, regions, ingredients, allergens, dietary status, alcohol percentages, or fees. Use null or empty arrays when unknown. Allergens are possible indicators, not guarantees. Currency should be a three-letter ISO code when reasonably inferable, otherwise USD. The response must match the supplied JSON schema.`;

  if (mode === "receipt") {
    return `${common}\nThis is a restaurant bill. Extract visible line items and totals. Determine whether gratuity, service charge, or another fee is already included. Set possibleDuplicateTipRisk true whenever another tip could duplicate an included gratuity or service charge. Set tipBase to the subtotal before tax when visible. Set menuType to unknown and return no menu sections.`;
  }
  return `${common}\nThis is a restaurant menu that may contain food, wine, cocktails, beer, other drinks, or a mixture, across multiple pages that may be supplied in any order. Combine all pages into one menu and remove only exact duplicates caused by overlapping photos. Preserve the printed item order within each section, but arrange sections in a natural dining order: appetizers and starters, soups, salads, entrees and mains, sides, desserts, non-alcoholic drinks and mocktails, cocktails, beer, spirits, then wine. Classify the overall menuType and every section and item. Do not merge distinct items merely because their names are similar.

For food: explain the dish in plain English, including cooking style and important ingredients only when reasonably supported by visible text. Keep every explanation concise: one short sentence of no more than 18 words. Translate foreign descriptions naturally and explain unfamiliar culinary terms. If an item name is already English, set englishName exactly equal to originalName; do not paraphrase it, change capitalization, split compound words, or append a category such as salad, soup, appetizer, entree, or dessert. Put helpful clarification in explanation instead. Only make englishName different when an actual translation is needed.

Classify an item from what the item itself is, not from ingredients mentioned in its description. A food dish cooked with wine, beer, spirits, coffee, or tea remains food and must not be classified as a drink.

For every menu price: preserve whether it is fixed, market price, a choice of prices, or priced by a unit. Keep market price as "MP". Keep multiple visible prices and their labels when available. Format per-unit prices unambiguously, for example "36/oz" or "12 per person"—never collapse "$36/oz" into "36oz". Do not place a serving weight or bottle size in the price field. If a fixed price is not visible, use null rather than inferring one.

For wine: every entry printed under a WINE, SPARKLING, WHITE, ORANGE, ROSÉ, RED, or other wine-list heading must have itemType "wine", a non-null wineDetails object, and drinkDetails null. Never classify those entries as generic drinks. Printed facts such as producer, vintage, grape, region, country, and prices must come from visible text; use null when absent. Even when printed facts are sparse, use the visible producer, wine name, grape, region, appellation, or recognized style to provide a concise typical profile: fill body, acidity, tannin, sweetness, flavors, general foodPairings, and servingSuggestion whenever reasonably supported. Set profileIsTypical true whenever any profile or pairing detail is inferred rather than printed. Do not imply that a typical characteristic was printed on the menu, and leave genuinely unsupported fields empty rather than guessing.

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

function compactResultSchema() {
  const nullableNumber = { anyOf: [{ type: "number" }, { type: "null" }] };
  const nullableString = { anyOf: [{ type: "string" }, { type: "null" }] };
  return {
    type: "object",
    additionalProperties: false,
    required: ["k", "mt", "l", "n", "r", "c", "s", "rec", "w"],
    properties: {
      k: { type: "string", enum: ["menu", "receipt"] },
      mt: { type: "string", enum: ["food", "wine", "drinks", "mixed", "unknown"] },
      l: { type: "string" },
      n: { type: "string" },
      r: nullableString,
      c: { type: "string" },
      s: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["n", "t", "i"],
          properties: {
            n: { type: "string" },
            t: { type: "string", enum: ["food", "wine", "drink", "mixed", "unknown"] },
            i: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                required: ["o", "e", "x", "p", "t", "d", "a", "sp", "wi", "dr"],
                properties: {
                  o: { type: "string" },
                  e: { type: "string" },
                  x: { type: "string" },
                  p: nullableString,
                  t: { type: "string", enum: ["food", "wine", "drink", "unknown"] },
                  d: { type: "array", items: { type: "string" } },
                  a: { type: "array", items: { type: "string" } },
                  sp: nullableString,
                  wi: compactWineDetailsSchema(nullableString),
                  dr: compactDrinkDetailsSchema(nullableString)
                }
              }
            }
          }
        }
      },
      rec: {
        anyOf: [
          { type: "null" },
          {
            type: "object",
            additionalProperties: false,
            required: ["sub", "tax", "sc", "scl", "tip", "tot", "tb", "ti", "dup", "li"],
            properties: {
              sub: nullableNumber,
              tax: nullableNumber,
              sc: nullableNumber,
              scl: nullableString,
              tip: nullableNumber,
              tot: nullableNumber,
              tb: nullableNumber,
              ti: { type: "boolean" },
              dup: { type: "boolean" },
              li: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  required: ["n", "a"],
                  properties: { n: { type: "string" }, a: { type: "number" } }
                }
              }
            }
          }
        ]
      },
      w: { type: "array", items: { type: "string" } }
    }
  };
}

function compactWineDetailsSchema(nullableString) {
  return {
    anyOf: [
      { type: "null" },
      compactWineObjectSchema(nullableString)
    ]
  };
}

function wineProfileResultSchema() {
  const nullableString = { anyOf: [{ type: "string" }, { type: "null" }] };
  return {
    type: "object",
    additionalProperties: false,
    required: ["w"],
    properties: {
      w: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["n", "d"],
          properties: {
            n: { type: "string" },
            d: compactWineObjectSchema(nullableString)
          }
        }
      }
    }
  };
}

function compactWineObjectSchema(nullableString) {
  return {
    type: "object",
    additionalProperties: false,
    required: ["p", "g", "r", "c", "v", "s", "gp", "bp", "b", "ac", "ta", "sw", "al", "f", "fp", "ss", "typ"],
    properties: {
      p: nullableString, g: nullableString, r: nullableString, c: nullableString,
      v: nullableString, s: nullableString, gp: nullableString, bp: nullableString,
      b: nullableString, ac: nullableString, ta: nullableString, sw: nullableString,
      al: nullableString,
      f: { type: "array", items: { type: "string" } },
      fp: { type: "array", items: { type: "string" } },
      ss: nullableString,
      typ: { type: "boolean" }
    }
  };
}

function compactDrinkDetailsSchema(nullableString) {
  return {
    anyOf: [
      { type: "null" },
      {
        type: "object",
        additionalProperties: false,
        required: ["t", "b", "i", "f", "a"],
        properties: {
          t: nullableString,
          b: nullableString,
          i: { type: "array", items: { type: "string" } },
          f: { type: "array", items: { type: "string" } },
          a: nullableString
        }
      }
    ]
  };
}

function expandCompactResult(value) {
  const expandWine = (wine) => wine === null ? null : {
    producer: wine.p,
    grape: wine.g,
    region: wine.r,
    country: wine.c,
    vintage: wine.v,
    style: wine.s,
    glassPrice: wine.gp,
    bottlePrice: wine.bp,
    body: wine.b,
    acidity: wine.ac,
    tannin: wine.ta,
    sweetness: wine.sw,
    alcohol: wine.al,
    flavors: wine.f,
    foodPairings: wine.fp,
    servingSuggestion: wine.ss,
    profileIsTypical: wine.typ
  };
  const expandDrink = (drink) => drink === null ? null : {
    drinkType: drink.t,
    baseSpirit: drink.b,
    ingredients: drink.i,
    flavorProfile: drink.f,
    abv: drink.a
  };
  const receipt = value.rec === null ? null : {
    subtotal: value.rec.sub,
    tax: value.rec.tax,
    serviceCharge: value.rec.sc,
    serviceChargeLabel: value.rec.scl,
    statedTip: value.rec.tip,
    total: value.rec.tot,
    tipBase: value.rec.tb,
    tipAlreadyIncluded: value.rec.ti,
    possibleDuplicateTipRisk: value.rec.dup,
    lineItems: value.rec.li.map((item) => ({ name: item.n, amount: item.a }))
  };
  return {
    kind: value.k,
    menuType: value.mt,
    detectedLanguage: value.l,
    notice: value.n,
    restaurantName: value.r,
    currencyCode: value.c,
    menuSections: value.s.map((section) => ({
      name: section.n,
      sectionType: section.t,
      items: section.i.map((item) => ({
        originalName: item.o,
        englishName: item.e,
        explanation: item.x,
        price: item.p,
        itemType: item.t,
        dietary: item.d,
        allergens: item.a,
        spiceLevel: item.sp,
        wineDetails: expandWine(item.wi),
        drinkDetails: expandDrink(item.dr)
      }))
    })),
    receipt,
    warnings: value.w
  };
}

function attachWineProfiles(pageResults, wineProfileResponses) {
  const profiles = wineProfileResponses.flatMap((response) => {
    const parsed = JSON.parse(response.output_text);
    return parsed.w.map((wine) => ({
      name: wine.n,
      key: normalizedText(wine.n),
      details: expandDedicatedWineDetails(wine.d)
    }));
  });
  for (const result of pageResults) {
    for (const section of result.menuSections) {
      for (const item of section.items) {
        const itemKey = normalizedText(item.originalName);
        const profile = profiles.find((candidate) => candidate.key === itemKey)
          || profiles.find((candidate) => itemKey.length >= 5 && candidate.key.length >= 5
            && (candidate.key.includes(itemKey) || itemKey.includes(candidate.key)));
        if (!profile) continue;
        item.itemType = "wine";
        item.wineDetails = profile.details;
        item.drinkDetails = null;
      }
    }
  }
  return profiles.length;
}

function expandDedicatedWineDetails(wine) {
  return {
    producer: wine.p,
    grape: wine.g,
    region: wine.r,
    country: wine.c,
    vintage: wine.v,
    style: wine.s,
    glassPrice: wine.gp,
    bottlePrice: wine.bp,
    body: wine.b,
    acidity: wine.ac,
    tannin: wine.ta,
    sweetness: wine.sw,
    alcohol: wine.al,
    flavors: wine.f,
    foodPairings: wine.fp,
    servingSuggestion: wine.ss,
    profileIsTypical: wine.typ
  };
}

function sumUsage(usages) {
  return usages.reduce((total, usage) => ({
    inputTokens: total.inputTokens + usage.inputTokens,
    cachedInputTokens: total.cachedInputTokens + usage.cachedInputTokens,
    outputTokens: total.outputTokens + usage.outputTokens,
    reasoningTokens: total.reasoningTokens + usage.reasoningTokens,
    totalTokens: total.totalTokens + usage.totalTokens
  }), {
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    reasoningTokens: 0,
    totalTokens: 0
  });
}

function mergeMenuResults(results) {
  const sectionMap = new Map();
  for (const result of results) {
    for (const section of result.menuSections) {
      const sectionKey = normalizedText(section.name) || `${section.sectionType}-${sectionMap.size}`;
      const existing = sectionMap.get(sectionKey);
      if (!existing) {
        sectionMap.set(sectionKey, { ...section, items: [...section.items] });
        continue;
      }
      const itemKeys = new Set(existing.items.map(menuItemKey));
      for (const item of section.items) {
        const itemKey = menuItemKey(item);
        if (!itemKeys.has(itemKey)) {
          existing.items.push(item);
          itemKeys.add(itemKey);
        }
      }
      if (existing.sectionType === "unknown" && section.sectionType !== "unknown") {
        existing.sectionType = section.sectionType;
      } else if (existing.sectionType !== section.sectionType) {
        existing.sectionType = "mixed";
      }
    }
  }
  const menuSections = [...sectionMap.values()].sort((left, right) => sectionRank(left) - sectionRank(right));
  const itemTypes = new Set(menuSections.flatMap((section) => section.items.map((item) => item.itemType)));
  itemTypes.delete("unknown");
  let menuType = "unknown";
  if (itemTypes.size > 1) menuType = "mixed";
  else if (itemTypes.has("food")) menuType = "food";
  else if (itemTypes.has("wine")) menuType = "wine";
  else if (itemTypes.has("drink")) menuType = "drinks";
  return {
    kind: "menu",
    menuType,
    detectedLanguage: firstUseful(results.map((result) => result.detectedLanguage)) || "unknown",
    notice: firstUseful(results.map((result) => result.notice)) || "",
    restaurantName: mostFrequentUseful(results.map((result) => result.restaurantName)),
    currencyCode: mostFrequentUseful(results.map((result) => result.currencyCode)) || "USD",
    menuSections,
    receipt: null,
    warnings: uniqueStrings(results.flatMap((result) => result.warnings))
  };
}

function menuItemKey(item) {
  return [normalizedText(item.originalName), normalizedText(item.price), item.itemType].join("|");
}

function normalizedText(value) {
  return String(value || "").trim().toLocaleLowerCase("en-US").replace(/\s+/g, " ");
}

function firstUseful(values) {
  return values.find((value) => normalizedText(value)) || null;
}

function mostFrequentUseful(values) {
  const counts = new Map();
  for (const value of values) {
    const key = normalizedText(value);
    if (!key) continue;
    const entry = counts.get(key) || { value, count: 0 };
    entry.count += 1;
    counts.set(key, entry);
  }
  return [...counts.values()].sort((left, right) => right.count - left.count)[0]?.value || null;
}

function uniqueStrings(values) {
  const seen = new Set();
  return values.filter((value) => {
    const key = normalizedText(value);
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function sectionRank(section) {
  const name = normalizedText(section.name);
  const groups = [
    ["appetizer", "starter", "first", "small plate", "raw", "caviar"],
    ["soup"],
    ["salad"],
    ["entree", "main", "turf", "surf", "steak", "seafood", "pasta"],
    ["side", "accompaniment"],
    ["dessert", "sweet"],
    ["zero proof", "mocktail", "non-alcoholic", "soft drink", "coffee", "tea"],
    ["cocktail"],
    ["beer", "ale", "lager"],
    ["spirit", "whiskey", "bourbon", "scotch", "tequila", "vodka", "gin", "rum"],
    ["wine", "champagne", "sparkling", "white", "red", "rosé", "rose"]
  ];
  const namedRank = groups.findIndex((terms) => terms.some((term) => name.includes(term)));
  if (namedRank >= 0) return namedRank;
  if (section.sectionType === "food") return 3;
  if (section.sectionType === "drink") return 7;
  if (section.sectionType === "wine") return 10;
  return 11;
}

function sanitizedSharedMenu(value) {
  if (!value || value.kind !== "menu" || !Array.isArray(value.menuSections)) {
    throw new HttpsError("invalid-argument", "Only scanned menus can be shared.");
  }
  const sections = value.menuSections.slice(0, 80).map((section) => ({
    name: sharedString(section?.name, 120),
    sectionType: sharedNullableString(section?.sectionType, 30),
    items: (Array.isArray(section?.items) ? section.items : []).slice(0, 250).map((item) => ({
      originalName: sharedString(item?.originalName, 180),
      englishName: sharedString(item?.englishName, 180),
      explanation: sharedString(item?.explanation, 600),
      price: sharedNullableString(item?.price, 80),
      itemType: sharedNullableString(item?.itemType, 30),
      dietary: sharedStringArray(item?.dietary, 20, 80),
      allergens: sharedStringArray(item?.allergens, 20, 80),
      spiceLevel: sharedNullableString(item?.spiceLevel, 80),
      wineDetails: sanitizedSharedWine(item?.wineDetails),
      drinkDetails: sanitizedSharedDrink(item?.drinkDetails)
    }))
  })).filter((section) => section.name && section.items.length);
  const menu = {
    kind: "menu",
    menuType: sharedNullableString(value.menuType, 30),
    detectedLanguage: sharedString(value.detectedLanguage, 80),
    notice: sharedString(value.notice, 600),
    restaurantName: sharedNullableString(value.restaurantName, 160),
    currencyCode: sharedString(value.currencyCode, 8) || "USD",
    menuSections: sections,
    receipt: null,
    warnings: []
  };
  if (!sections.length || JSON.stringify(menu).length > 750_000) {
    throw new HttpsError("invalid-argument", "This menu is too large to share.");
  }
  return menu;
}

function sanitizedSharedWine(wine) {
  if (!wine || typeof wine !== "object") return null;
  return {
    producer: sharedNullableString(wine.producer, 160),
    grape: sharedNullableString(wine.grape, 120),
    region: sharedNullableString(wine.region, 160),
    country: sharedNullableString(wine.country, 100),
    vintage: sharedNullableString(wine.vintage, 40),
    style: sharedNullableString(wine.style, 120),
    glassPrice: sharedNullableString(wine.glassPrice, 80),
    bottlePrice: sharedNullableString(wine.bottlePrice, 80),
    body: sharedNullableString(wine.body, 100),
    acidity: sharedNullableString(wine.acidity, 100),
    tannin: sharedNullableString(wine.tannin, 100),
    sweetness: sharedNullableString(wine.sweetness, 100),
    alcohol: sharedNullableString(wine.alcohol, 80),
    flavors: sharedStringArray(wine.flavors, 20, 100),
    foodPairings: sharedStringArray(wine.foodPairings, 20, 120),
    servingSuggestion: sharedNullableString(wine.servingSuggestion, 300),
    profileIsTypical: wine.profileIsTypical === true
  };
}

function sanitizedSharedDrink(drink) {
  if (!drink || typeof drink !== "object") return null;
  return {
    drinkType: sharedNullableString(drink.drinkType, 100),
    baseSpirit: sharedNullableString(drink.baseSpirit, 100),
    ingredients: sharedStringArray(drink.ingredients, 30, 120),
    flavorProfile: sharedStringArray(drink.flavorProfile, 20, 100),
    abv: sharedNullableString(drink.abv, 80)
  };
}

function sharedString(value, maximumLength) {
  return String(value || "").trim().slice(0, maximumLength);
}

function sharedNullableString(value, maximumLength) {
  const string = sharedString(value, maximumLength);
  return string || null;
}

function sharedStringArray(value, maximumCount, maximumLength) {
  if (!Array.isArray(value)) return [];
  return value.slice(0, maximumCount).map((item) => sharedString(item, maximumLength)).filter(Boolean);
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
  const overrideRef = admin.firestore().collection("proAccessOverrides").doc(uid);
  const [snapshot, overrideSnapshot] = await Promise.all([ref.get(), overrideRef.get()]);
  const data = snapshot.data() || {};
  const introductoryUsed = Number(data.introductoryUsed || 0);

  // Client access to these collections is denied by Firestore rules, so only
  // an administrator can grant internal testing access.
  if (overrideSnapshot.data()?.enabled === true) {
    return { allowed: true, type: "override", introductoryUsed };
  }

  // Preserve the original Vemuni-specific testing flag for existing testers.
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
      ...scanMetrics.timing,
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
    ...scanMetrics.timing,
    ...usage,
    createdAt: admin.firestore.FieldValue.serverTimestamp()
  });
  await batch.commit();
}
